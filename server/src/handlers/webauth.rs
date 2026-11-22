//! Signing in to the AZET Pass account with a passkey (spass-092), on Bitwarden's wire shape: the web vault makes a
//! passkey in Settings > Security (POST /api/webauthn/attestation-options, then POST /api/webauthn) and signs in
//! with it (GET /identity/accounts/webauthn/assertion-options, then grant_type=webauthn). With PRF the passkey also
//! unlocks: the client stores its user key wrapped by a key only the passkey can give (we never see either).
//! Signatures are checked with the runtime's WebCrypto (ES256, RS256, Ed25519); only `none` attestation is asked.
use axum::extract::{Path, State};
use axum::Json;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::sync::Arc;
use uuid::Uuid;
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::JsFuture;
use worker::{js_sys, Env};

use crate::auth::Claims;
use crate::d1_query;
use crate::db;
use crate::error::AppError;

const MAX_CREDENTIALS: usize = 5;
const CHALLENGE_MINUTES: f64 = 5.0;
const PRF_ENABLED: i64 = 0;
const PRF_SUPPORTED: i64 = 1;
const PRF_UNSUPPORTED: i64 = 2;

fn bad(msg: &str) -> AppError {
    AppError::BadRequest(msg.to_string())
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(|x| x.to_string())
}

/// The web vault's address; the passkey is bound to its host (the relying party).
fn origin(env: &Env) -> String {
    env.var("WEBAUTHN_ORIGIN").map(|v| v.to_string()).unwrap_or_else(|_| "https://pass.azet.io".into())
}

fn rp_id(origin: &str) -> String {
    origin.split("://").nth(1).unwrap_or(origin).split([':', '/']).next().unwrap_or_default().to_string()
}

/// Clients send base64url (no padding); some send standard base64.
fn unb64(text: &str) -> Result<Vec<u8>, AppError> {
    let t = text.trim_end_matches('=');
    URL_SAFE_NO_PAD
        .decode(t)
        .or_else(|_| STANDARD.decode(text))
        .map_err(|_| bad("bad base64"))
}

fn b64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

// ---- CBOR, only as much as attestation objects and COSE keys use ----

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum Cbor {
    Int(i128),
    Bytes(Vec<u8>),
    Text(String),
    Array(Vec<Cbor>),
    Map(Vec<(Cbor, Cbor)>),
    Simple,
}

impl Cbor {
    fn get(&self, key: &Cbor) -> Option<&Cbor> {
        match self {
            Cbor::Map(m) => m.iter().find(|(k, _)| k == key).map(|(_, v)| v),
            _ => None,
        }
    }
    fn int(&self, k: i128) -> Option<&Cbor> {
        self.get(&Cbor::Int(k))
    }
    fn text(&self, k: &str) -> Option<&Cbor> {
        self.get(&Cbor::Text(k.into()))
    }
    fn bytes(&self) -> Option<&[u8]> {
        match self {
            Cbor::Bytes(b) => Some(b),
            _ => None,
        }
    }
    fn as_int(&self) -> Option<i128> {
        match self {
            Cbor::Int(i) => Some(*i),
            _ => None,
        }
    }
}

/// One CBOR item from `buf` at `*pos`; `*pos` ends after it. Indefinite lengths are refused.
pub(crate) fn cbor(buf: &[u8], pos: &mut usize, depth: u8) -> Result<Cbor, AppError> {
    let err = || bad("bad CBOR");
    if depth > 16 {
        return Err(err());
    }
    let head = *buf.get(*pos).ok_or_else(err)?;
    *pos += 1;
    let (major, info) = (head >> 5, head & 0x1f);
    let mut take = |n: usize| -> Result<&[u8], AppError> {
        let s = buf.get(*pos..*pos + n).ok_or_else(err)?;
        *pos += n;
        Ok(s)
    };
    let arg: u64 = match info {
        0..=23 => info as u64,
        24 => take(1)?[0] as u64,
        25 => u16::from_be_bytes(take(2)?.try_into().unwrap()) as u64,
        26 => u32::from_be_bytes(take(4)?.try_into().unwrap()) as u64,
        27 => u64::from_be_bytes(take(8)?.try_into().unwrap()),
        _ => return Err(err()),
    };
    let len = usize::try_from(arg).map_err(|_| err())?;
    Ok(match major {
        0 => Cbor::Int(arg as i128),
        1 => Cbor::Int(-1 - arg as i128),
        2 => Cbor::Bytes(take(len)?.to_vec()),
        3 => Cbor::Text(String::from_utf8(take(len)?.to_vec()).map_err(|_| err())?),
        4 => {
            let mut v = Vec::new();
            for _ in 0..len.min(buf.len()) {
                v.push(cbor(buf, pos, depth + 1)?);
            }
            Cbor::Array(v)
        }
        5 => {
            let mut v = Vec::new();
            for _ in 0..len.min(buf.len()) {
                let k = cbor(buf, pos, depth + 1)?;
                v.push((k, cbor(buf, pos, depth + 1)?));
            }
            Cbor::Map(v)
        }
        6 => cbor(buf, pos, depth + 1)?, // a tag: the tagged item
        _ => Cbor::Simple,               // true, false, null, floats (the argument bytes were taken above)
    })
}

/// A COSE public key as a JWK and the WebCrypto names to check its signatures with.
pub(crate) fn cose_to_jwk(key: &Cbor) -> Result<(Value, i64), AppError> {
    let b = |k: i128| key.int(k).and_then(Cbor::bytes).map(b64url).ok_or_else(|| bad("COSE key"));
    let kty = key.int(1).and_then(Cbor::as_int);
    let alg = key.int(3).and_then(Cbor::as_int).ok_or_else(|| bad("COSE alg"))? as i64;
    match (kty, alg) {
        (Some(2), -7) if key.int(-1).and_then(Cbor::as_int) == Some(1) => Ok((json!({"kty": "EC", "crv": "P-256", "x": b(-2)?, "y": b(-3)?}), alg)),
        (Some(3), -257) => Ok((json!({"kty": "RSA", "n": b(-1)?, "e": b(-2)?}), alg)),
        (Some(1), -8) if key.int(-1).and_then(Cbor::as_int) == Some(6) => Ok((json!({"kty": "OKP", "crv": "Ed25519", "x": b(-2)?}), alg)),
        _ => Err(bad("This passkey's key type is not supported (ES256, RS256 or Ed25519).")),
    }
}

pub(crate) struct AuthData {
    rp_id_hash: Vec<u8>,
    flags: u8,
    counter: u32,
    credential: Option<(Vec<u8>, Cbor)>,
}

pub(crate) fn auth_data(d: &[u8]) -> Result<AuthData, AppError> {
    if d.len() < 37 {
        return Err(bad("authenticator data"));
    }
    let flags = d[32];
    let mut out = AuthData { rp_id_hash: d[..32].to_vec(), flags, counter: u32::from_be_bytes(d[33..37].try_into().unwrap()), credential: None };
    if flags & 0x40 != 0 {
        let n = u16::from_be_bytes(d.get(53..55).ok_or_else(|| bad("credential data"))?.try_into().unwrap()) as usize;
        let id = d.get(55..55 + n).ok_or_else(|| bad("credential id"))?.to_vec();
        let mut pos = 55 + n;
        let key = cbor(d, &mut pos, 0)?;
        out.credential = Some((id, key));
    }
    Ok(out)
}

/// ECDSA signatures arrive DER-encoded; WebCrypto takes r || s.
pub(crate) fn der_to_raw(der: &[u8]) -> Result<Vec<u8>, AppError> {
    let err = || bad("signature");
    if der.first() != Some(&0x30) || der.len() < 8 {
        return Err(err());
    }
    let mut pos = 2;
    let mut out = Vec::with_capacity(64);
    for _ in 0..2 {
        if der.get(pos) != Some(&0x02) {
            return Err(err());
        }
        let n = *der.get(pos + 1).ok_or_else(err)? as usize;
        let int = der.get(pos + 2..pos + 2 + n).ok_or_else(err)?;
        let int = &int[int.iter().position(|b| *b != 0).unwrap_or(int.len())..];
        if int.len() > 32 {
            return Err(err());
        }
        out.extend(std::iter::repeat_n(0u8, 32 - int.len()));
        out.extend_from_slice(int);
        pos += 2 + n;
    }
    Ok(out)
}

fn js(text: &str) -> Result<js_sys::Object, AppError> {
    js_sys::JSON::parse(text).map_err(|_| AppError::Internal)?.dyn_into().map_err(|_| AppError::Internal)
}

async fn signature_ok(jwk: &str, alg: i64, signature: &[u8], data: &[u8]) -> Result<bool, AppError> {
    let (import, verify, sig) = match alg {
        -7 => (r#"{"name":"ECDSA","namedCurve":"P-256"}"#, r#"{"name":"ECDSA","hash":"SHA-256"}"#, der_to_raw(signature)?),
        -257 => (r#"{"name":"RSASSA-PKCS1-v1_5","hash":"SHA-256"}"#, r#"{"name":"RSASSA-PKCS1-v1_5"}"#, signature.to_vec()),
        -8 => (r#"{"name":"Ed25519"}"#, r#"{"name":"Ed25519"}"#, signature.to_vec()),
        _ => return Ok(false),
    };
    let subtle = js_sys::Reflect::get(&js_sys::global(), &"crypto".into())
        .map_err(|_| AppError::Internal)?
        .dyn_into::<web_sys::Crypto>()
        .map_err(|_| AppError::Internal)?
        .subtle();
    let usages = js_sys::Array::of1(&"verify".into());
    let key: web_sys::CryptoKey = JsFuture::from(subtle.import_key_with_object("jwk", &js(jwk)?, &js(import)?, false, &usages).map_err(|_| AppError::Internal)?)
        .await
        .map_err(|_| bad("passkey public key"))?
        .dyn_into()
        .map_err(|_| AppError::Internal)?;
    let sig = js_sys::Uint8Array::from(sig.as_slice());
    let data = js_sys::Uint8Array::from(data);
    let ok = JsFuture::from(subtle.verify_with_object_and_buffer_source_and_buffer_source(&js(verify)?, &key, &sig, &data).map_err(|_| AppError::Internal)?)
        .await
        .map_err(|_| AppError::Internal)?;
    Ok(ok.as_bool() == Some(true))
}

/// clientDataJSON: the right ceremony, our challenge, our web vault.
pub(crate) fn client_data_ok(raw: &[u8], kind: &str, challenge: &str, origin: &str) -> Result<(), AppError> {
    let c: Value = serde_json::from_slice(raw).map_err(|_| bad("client data"))?;
    if s(&c, "type").as_deref() != Some(kind) || s(&c, "challenge").as_deref().map(|x| x.trim_end_matches('=')) != Some(challenge) || s(&c, "origin").as_deref() != Some(origin) {
        return Err(bad("This passkey answer is not for this request."));
    }
    Ok(())
}

pub(crate) fn auth_flags_ok(a: &AuthData, rp: &str) -> Result<(), AppError> {
    if a.rp_id_hash != Sha256::digest(rp.as_bytes()).as_slice() {
        return Err(bad("This passkey is for another site."));
    }
    if a.flags & 0x01 == 0 || a.flags & 0x04 == 0 {
        return Err(bad("The passkey did not check it was you (user verification)."));
    }
    Ok(())
}

// ---- one-time challenges ----

async fn new_challenge(db: &db::Db, user_id: Option<&str>, kind: &str) -> Result<(String, String), AppError> {
    let mut buf = [0u8; 32];
    getrandom::fill(&mut buf).map_err(|_| AppError::Internal)?;
    let challenge = b64url(&buf);
    let token = Uuid::new_v4().to_string();
    d1_query!(db, "DELETE FROM webauthn_challenges WHERE datetime(created_at, '+' || ?1 || ' minutes') < datetime('now')", CHALLENGE_MINUTES)
        .map_err(|_| AppError::Database)?.run().await?;
    d1_query!(db, "INSERT INTO webauthn_challenges (token, user_id, challenge, kind, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
        token, user_id, challenge, kind, db::now_string())
        .map_err(|_| AppError::Database)?.run().await?;
    Ok((token, challenge))
}

/// The challenge of a token, used once: (user id it was made for, challenge).
async fn take_challenge(db: &db::Db, token: &str, kind: &str) -> Result<(Option<String>, String), AppError> {
    let row: Option<Value> = db
        .prepare("SELECT user_id, challenge FROM webauthn_challenges WHERE token = ?1 AND kind = ?2
            AND datetime(created_at, '+' || ?3 || ' minutes') >= datetime('now')")
        .bind(&[token.into(), kind.into(), CHALLENGE_MINUTES.into()])?
        .first(None)
        .await?;
    d1_query!(db, "DELETE FROM webauthn_challenges WHERE token = ?1", token).map_err(|_| AppError::Database)?.run().await?;
    let row = row.ok_or_else(|| bad("This passkey request ran out. Try again."))?;
    Ok((s(&row, "user_id"), s(&row, "challenge").unwrap_or_default()))
}

async fn credentials(db: &db::Db, user_id: &str) -> Result<Vec<Value>, AppError> {
    Ok(db.prepare("SELECT * FROM webauthn_credentials WHERE user_id = ?1 ORDER BY created_at").bind(&[user_id.into()])?.all().await?.results()?)
}

fn secret(p: &Value) -> String {
    s(p, "masterPasswordHash").or_else(|| s(p, "secret")).unwrap_or_default()
}

/// An assertion (deviceResponse of navigator.credentials.get) checked against the stored passkey; its counter moves.
async fn check_assertion(db: &db::Db, env: &Env, challenge: &str, r: &Value, user_id: Option<&str>) -> Result<Value, AppError> {
    let raw_id = b64url(&unb64(&s(r, "rawId").or_else(|| s(r, "id")).ok_or_else(|| bad("rawId"))?)?);
    let resp = r.get("response").ok_or_else(|| bad("response"))?;
    let field = |k: &str| s(resp, k).ok_or_else(|| bad(k)).and_then(|x| unb64(&x));
    let (auth, client, sig) = (field("authenticatorData")?, field("clientDataJSON").or_else(|_| field("clientDataJson"))?, field("signature")?);
    let cred: Value = db
        .prepare("SELECT * FROM webauthn_credentials WHERE credential_id = ?1")
        .bind(&[raw_id.into()])?
        .first(None)
        .await?
        .ok_or_else(|| bad("This passkey is not saved on any AZET Pass account."))?;
    if user_id.is_some_and(|u| s(&cred, "user_id").as_deref() != Some(u)) {
        return Err(bad("This passkey belongs to another account."));
    }
    let o = origin(env);
    client_data_ok(&client, "webauthn.get", challenge, &o)?;
    let a = auth_data(&auth)?;
    auth_flags_ok(&a, &rp_id(&o))?;
    let mut signed = auth.clone();
    signed.extend_from_slice(&Sha256::digest(&client));
    if !signature_ok(&s(&cred, "public_key").unwrap_or_default(), cred["alg"].as_i64().unwrap_or(0), &sig, &signed).await? {
        return Err(bad("The passkey signature does not match."));
    }
    let stored = cred["counter"].as_i64().unwrap_or(0);
    if a.counter != 0 && i64::from(a.counter) <= stored {
        return Err(bad("This passkey may have been copied (its counter went back)."));
    }
    d1_query!(db, "UPDATE webauthn_credentials SET counter = ?1, updated_at = ?2 WHERE id = ?3", a.counter as i64, db::now_string(), s(&cred, "id"))
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(cred)
}

fn device_response(p: &Value) -> Result<Value, AppError> {
    match p.get("deviceResponse") {
        Some(Value::String(t)) => serde_json::from_str(t).map_err(|_| bad("deviceResponse")),
        Some(v @ Value::Object(_)) => Ok(v.clone()),
        _ => Err(bad("deviceResponse")),
    }
}

fn assertion_options(challenge: &str, rp: &str, allow: Vec<Value>) -> Value {
    json!({"challenge": challenge, "allowCredentials": allow, "rpId": rp, "timeout": 60000, "userVerification": "required",
        "extensions": {}, "status": "ok", "errorMessage": ""})
}

// ---- handlers ----

/// GET /api/webauthn — the account's passkeys.
#[worker::send]
pub async fn get_webauthn_credentials(claims: Claims, State(env): State<Arc<Env>>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let data: Vec<Value> = credentials(&db, &claims.sub)
        .await?
        .iter()
        .map(|c| json!({"object": "webauthnCredential", "id": c["id"], "name": c["name"], "prfStatus": c["prf_status"],
            "encryptedUserKey": c["encrypted_user_key"], "encryptedPublicKey": c["encrypted_public_key"]}))
        .collect();
    Ok(Json(json!({"object": "list", "data": data, "continuationToken": null})))
}

/// POST /api/webauthn/attestation-options {masterPasswordHash | secret}
#[worker::send]
pub async fn attestation_options(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user = crate::handlers::accounts::checked_user(&db, &claims.sub, &secret(&p)).await?;
    let have = credentials(&db, &claims.sub).await?;
    if have.len() >= MAX_CREDENTIALS {
        return Err(bad("An account keeps at most 5 passkeys; remove one first."));
    }
    let (token, challenge) = new_challenge(&db, Some(&claims.sub), "create").await?;
    let exclude: Vec<Value> = have.iter().map(|c| json!({"type": "public-key", "id": c["credential_id"]})).collect();
    let o = origin(&env);
    Ok(Json(json!({"object": "webauthnCredentialCreateOptions", "token": token, "options": {
        "rp": {"id": rp_id(&o), "name": "AZET Pass"},
        "user": {"id": b64url(claims.sub.as_bytes()), "name": user.email, "displayName": user.name.clone().unwrap_or_else(|| user.email.clone())},
        "challenge": challenge,
        "pubKeyCredParams": [{"type": "public-key", "alg": -7}, {"type": "public-key", "alg": -8}, {"type": "public-key", "alg": -257}],
        "timeout": 60000, "attestation": "none", "excludeCredentials": exclude,
        "authenticatorSelection": {"residentKey": "required", "requireResidentKey": true, "userVerification": "required"},
        "extensions": {}, "status": "ok", "errorMessage": ""
    }})))
}

/// POST /api/webauthn {deviceResponse, name, token, supportsPrf, encryptedUserKey?, encryptedPublicKey?, encryptedPrivateKey?}
#[worker::send]
pub async fn save_credential(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let (owner, challenge) = take_challenge(&db, &s(&p, "token").unwrap_or_default(), "create").await?;
    if owner.as_deref() != Some(claims.sub.as_str()) {
        return Err(bad("This passkey request is for another account."));
    }
    let r = device_response(&p)?;
    let resp = r.get("response").ok_or_else(|| bad("response"))?;
    let client = unb64(&s(resp, "clientDataJson").or_else(|| s(resp, "clientDataJSON")).ok_or_else(|| bad("clientDataJson"))?)?;
    let o = origin(&env);
    client_data_ok(&client, "webauthn.create", &challenge, &o)?;
    let att = unb64(&s(resp, "attestationObject").ok_or_else(|| bad("attestationObject"))?)?;
    let att = cbor(&att, &mut 0, 0)?;
    let a = auth_data(att.text("authData").and_then(Cbor::bytes).ok_or_else(|| bad("authData"))?)?;
    auth_flags_ok(&a, &rp_id(&o))?;
    let (id, key) = a.credential.as_ref().ok_or_else(|| bad("The passkey sent no key."))?;
    let (jwk, alg) = cose_to_jwk(key)?;
    let name = s(&p, "name").map(|n| n.chars().take(50).collect::<String>()).filter(|n| !n.trim().is_empty()).ok_or_else(|| bad("name"))?;
    let keys = [s(&p, "encryptedUserKey"), s(&p, "encryptedPublicKey"), s(&p, "encryptedPrivateKey")];
    let prf = if keys.iter().all(Option::is_some) {
        PRF_ENABLED
    } else if p["supportsPrf"].as_bool() == Some(true) {
        PRF_SUPPORTED
    } else {
        PRF_UNSUPPORTED
    };
    let now = db::now_string();
    d1_query!(&db, "INSERT INTO webauthn_credentials (id, user_id, name, credential_id, public_key, alg, counter, prf_status,
            encrypted_user_key, encrypted_public_key, encrypted_private_key, created_at, updated_at)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12)",
        Uuid::new_v4().to_string(), claims.sub, name, b64url(id), jwk.to_string(), alg, a.counter as i64, prf,
        keys[0].clone(), keys[1].clone(), keys[2].clone(), now)
        .map_err(|_| AppError::Database)?.run().await
        .map_err(|_| bad("This passkey is already saved."))?;
    Ok(Json(json!({})))
}

/// POST /api/webauthn/assertion-options {masterPasswordHash | secret} — to turn on unlock with an existing passkey.
#[worker::send]
pub async fn update_assertion_options(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    crate::handlers::accounts::checked_user(&db, &claims.sub, &secret(&p)).await?;
    let allow: Vec<Value> = credentials(&db, &claims.sub).await?.iter().map(|c| json!({"type": "public-key", "id": c["credential_id"]})).collect();
    let (token, challenge) = new_challenge(&db, Some(&claims.sub), "update").await?;
    Ok(Json(json!({"object": "webAuthnLoginAssertionOptions", "token": token, "options": assertion_options(&challenge, &rp_id(&origin(&env)), allow)})))
}

/// PUT /api/webauthn {deviceResponse, token, encryptedUserKey, encryptedPublicKey, encryptedPrivateKey}
#[worker::send]
pub async fn update_credential(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let (owner, challenge) = take_challenge(&db, &s(&p, "token").unwrap_or_default(), "update").await?;
    if owner.as_deref() != Some(claims.sub.as_str()) {
        return Err(bad("This passkey request is for another account."));
    }
    let cred = check_assertion(&db, &env, &challenge, &device_response(&p)?, Some(&claims.sub)).await?;
    let keys = [s(&p, "encryptedUserKey"), s(&p, "encryptedPublicKey"), s(&p, "encryptedPrivateKey")];
    if keys.iter().any(Option::is_none) {
        return Err(bad("encryptedUserKey, encryptedPublicKey and encryptedPrivateKey"));
    }
    d1_query!(&db, "UPDATE webauthn_credentials SET prf_status = ?1, encrypted_user_key = ?2, encrypted_public_key = ?3, encrypted_private_key = ?4, updated_at = ?5 WHERE id = ?6",
        PRF_ENABLED, keys[0].clone(), keys[1].clone(), keys[2].clone(), db::now_string(), s(&cred, "id"))
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

/// POST /api/webauthn/{id}/delete {masterPasswordHash | secret}
#[worker::send]
pub async fn delete_credential(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    crate::handlers::accounts::checked_user(&db, &claims.sub, &secret(&p)).await?;
    d1_query!(&db, "DELETE FROM webauthn_credentials WHERE id = ?1 AND user_id = ?2", id, claims.sub)
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

/// GET /identity/accounts/webauthn/assertion-options — a discoverable-passkey sign-in (no account named yet).
#[worker::send]
pub async fn login_assertion_options(State(env): State<Arc<Env>>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let (token, challenge) = new_challenge(&db, None, "login").await?;
    Ok(Json(json!({"object": "webAuthnLoginAssertionOptions", "token": token, "options": assertion_options(&challenge, &rp_id(&origin(&env)), vec![])})))
}

/// grant_type=webauthn: the account the passkey belongs to, and its unlock keys when the passkey has PRF on.
pub(crate) async fn verify_login(db: &db::Db, env: &Env, token: &str, device_response_json: &str) -> Result<(String, Option<Value>), AppError> {
    let (_, challenge) = take_challenge(db, token, "login").await?;
    let r: Value = serde_json::from_str(device_response_json).map_err(|_| bad("deviceResponse"))?;
    let cred = check_assertion(db, env, &challenge, &r, None).await?;
    let prf = (cred["prf_status"].as_i64() == Some(PRF_ENABLED)).then(|| {
        json!({"EncryptedPrivateKey": cred["encrypted_private_key"], "EncryptedUserKey": cred["encrypted_user_key"],
            "CredentialId": cred["credential_id"], "Transports": []})
    });
    Ok((s(&cred, "user_id").unwrap_or_default(), prf))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_cbor_maps_with_int_and_text_keys() {
        // {1: 2, 3: -7, -1: 1, "fmt": "none", -2: h'0102'}
        let buf = [0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x63, b'f', b'm', b't', 0x64, b'n', b'o', b'n', b'e', 0x21, 0x42, 1, 2];
        let m = cbor(&buf, &mut 0, 0).unwrap();
        assert_eq!(m.int(3), Some(&Cbor::Int(-7)));
        assert_eq!(m.text("fmt"), Some(&Cbor::Text("none".into())));
        assert_eq!(m.int(-2).and_then(Cbor::bytes), Some(&[1u8, 2][..]));
        assert!(cbor(&[0x5f], &mut 0, 0).is_err(), "indefinite length");
        assert!(cbor(&[0x42, 1], &mut 0, 0).is_err(), "short bytes");
    }

    #[test]
    fn ec2_cose_key_becomes_a_jwk() {
        let k = Cbor::Map(vec![
            (Cbor::Int(1), Cbor::Int(2)),
            (Cbor::Int(3), Cbor::Int(-7)),
            (Cbor::Int(-1), Cbor::Int(1)),
            (Cbor::Int(-2), Cbor::Bytes(vec![1; 32])),
            (Cbor::Int(-3), Cbor::Bytes(vec![2; 32])),
        ]);
        let (jwk, alg) = cose_to_jwk(&k).unwrap();
        assert_eq!(alg, -7);
        assert_eq!(jwk["crv"], "P-256");
        assert_eq!(jwk["x"], b64url(&[1; 32]));
        let other = Cbor::Map(vec![(Cbor::Int(1), Cbor::Int(2)), (Cbor::Int(3), Cbor::Int(-35))]);
        assert!(cose_to_jwk(&other).is_err());
    }

    #[test]
    fn der_signature_becomes_raw() {
        // r = 0x00 || 0x80..(32 bytes with a leading zero for sign), s = 0x01
        let mut der = vec![0x30, 0x26, 0x02, 0x21, 0x00];
        der.extend([0x80; 32]);
        der.extend([0x02, 0x01, 0x01]);
        let raw = der_to_raw(&der).unwrap();
        assert_eq!(raw.len(), 64);
        assert_eq!(&raw[..32], &[0x80; 32]);
        assert_eq!(raw[63], 1);
        assert!(raw[32..63].iter().all(|b| *b == 0));
    }

    #[test]
    fn client_data_and_flags_are_checked() {
        let cd = br#"{"type":"webauthn.get","challenge":"abc","origin":"https://pass.azet.io"}"#;
        assert!(client_data_ok(cd, "webauthn.get", "abc", "https://pass.azet.io").is_ok());
        assert!(client_data_ok(cd, "webauthn.create", "abc", "https://pass.azet.io").is_err());
        assert!(client_data_ok(cd, "webauthn.get", "abd", "https://pass.azet.io").is_err());
        assert!(client_data_ok(cd, "webauthn.get", "abc", "https://evil.example").is_err());
        let mut d = Sha256::digest(b"pass.azet.io").to_vec();
        d.extend([0x05, 0, 0, 0, 1]);
        let a = auth_data(&d).unwrap();
        assert_eq!(a.counter, 1);
        assert!(auth_flags_ok(&a, "pass.azet.io").is_ok());
        assert!(auth_flags_ok(&a, "azet.io").is_err());
        d[32] = 0x01; // present, not verified
        assert!(auth_flags_ok(&auth_data(&d).unwrap(), "pass.azet.io").is_err());
        assert_eq!(rp_id("https://pass.azet.io"), "pass.azet.io");
        assert_eq!(rp_id("http://localhost:8080"), "localhost");
    }
}
