//! Changing a shared vault's key. A member who was removed (or who left) has seen the vault key and the vault's RSA
//! private key, so the organizer's device makes new ones, seals everything the old key sealed again, and sends it all
//! here in one request. The server never sees a key: it checks that nothing the old key sealed is left out, that
//! every text is ciphertext, and writes the lot in one D1 batch (all of it or none of it).
//!
//! After a change a device that has not synced still holds the old key. What it would save could be opened by nobody
//! once the others sync, so each vault has a key generation, a sync records the generation a device received, and a
//! write into the vault from a device that has not received the current one is refused (400) until it syncs.
use axum::extract::{Path, State};
use axum::Json;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use worker::Env;

use super::family::{log_event, organizer, touch_org_users};
use crate::auth::Claims;
use crate::d1_query;
use crate::db;
use crate::error::AppError;
use crate::models::cipher::{is_ciphertext, CipherData};

fn bad(msg: &str) -> AppError {
    AppError::BadRequest(msg.to_string())
}

fn text(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(String::from)
}

/// A sealed value from the request, or 400 naming it. Wrapped keys (`4.…`) and EncStrings (`2.…`) both pass.
fn sealed(v: &Value, k: &str) -> Result<String, AppError> {
    text(v, k).filter(|t| is_ciphertext(t)).ok_or_else(|| bad(&format!("{k} is missing or not encrypted")))
}

async fn rows(db: &db::Db, sql: &str, org_id: &str) -> Result<Vec<Value>, AppError> {
    Ok(db.prepare(sql).bind(&[org_id.into()])?.all().await?.results()?)
}

async fn generation(db: &db::Db, org_id: &str) -> Result<i64, AppError> {
    let org: Value = db
        .prepare("SELECT key_gen FROM organizations WHERE id = ?1")
        .bind(&[org_id.into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::NotFound("Organization not found".into()))?;
    Ok(org["key_gen"].as_i64().unwrap_or(1))
}

/// Refuses a write into a shared vault from a device that has not received the vault's current key.
/// A vault whose key was never changed (generation 1) asks nothing, so no device is refused before a first change.
pub async fn key_current(db: &db::Db, org_id: Option<&str>, device: &str) -> Result<(), AppError> {
    let Some(org_id) = org_id else {
        return Ok(());
    };
    let gen = generation(db, org_id).await?;
    if gen <= 1 {
        return Ok(());
    }
    let seen: Option<Value> = db
        .prepare("SELECT 1 FROM org_key_seen WHERE device = ?1 AND org_id = ?2 AND gen = ?3")
        .bind(&[device.into(), org_id.into(), (gen as f64).into()])?
        .first(None)
        .await?;
    match seen {
        Some(_) => Ok(()),
        None => Err(bad("The key of this shared vault was changed. Sync this device, then try again.")),
    }
}

/// Called by the sync that hands a device its vault keys: this device now holds the current key of each vault
/// the account is a confirmed member of. Only vaults whose key was changed are recorded.
pub async fn mark_seen(db: &db::Db, user_id: &str, device: &str) -> Result<(), AppError> {
    d1_query!(
        db,
        "INSERT INTO org_key_seen (device, org_id, gen) \
         SELECT ?1, o.id, o.key_gen FROM org_members m JOIN organizations o ON o.id = m.org_id \
         WHERE m.user_id = ?2 AND m.status = 2 AND m.akey IS NOT NULL AND o.key_gen > 1 \
           AND (m.access_until IS NULL OR m.access_until > ?3) \
         ON CONFLICT(device, org_id) DO UPDATE SET gen = excluded.gen WHERE org_key_seen.gen <> excluded.gen",
        device,
        user_id,
        db::now_string()
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await?;
    Ok(())
}

const MEMBERS: &str = "SELECT m.id, m.user_id, m.email, m.status, m.akey, m.reset_password_key, u.public_key \
    FROM org_members m LEFT JOIN users u ON u.id = m.user_id WHERE m.org_id = ?1";
const COLLECTIONS: &str = "SELECT id, name FROM collections WHERE org_id = ?1";
const CIPHERS: &str = "SELECT id, data, updated_at FROM ciphers WHERE organization_id = ?1";
const FILES: &str = "SELECT a.id, a.cipher_id, a.file_name, a.akey FROM attachments a JOIN ciphers c ON c.id = a.cipher_id WHERE c.organization_id = ?1";
const PENDING: &str = "SELECT a.id FROM attachments_pending a JOIN ciphers c ON c.id = a.cipher_id WHERE c.organization_id = ?1";

/// GET /api/organizations/{org_id}/azet/rotation — everything the vault key seals, for the organizer's device to
/// seal again: the vault's key pair, the log checkpoint, each member's wrapped key, vault names, items (those in the
/// trash too) and file names.
#[worker::send]
pub async fn rotation(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    organizer(&db, &org_id, &claims.sub).await?;
    let org: Value = db
        .prepare("SELECT public_key, private_key, log_checkpoint, member_pins, key_gen, rotate_due FROM organizations WHERE id = ?1")
        .bind(&[org_id.clone().into()])?
        .first(None)
        .await?
        .ok_or(AppError::Internal)?;
    let ciphers: Vec<Value> = rows(&db, CIPHERS, &org_id)
        .await?
        .into_iter()
        .map(|c| {
            let data = c["data"].as_str().and_then(|d| serde_json::from_str::<Value>(d).ok()).unwrap_or(Value::Null);
            json!({"id": c["id"], "updatedAt": c["updated_at"], "cipher": data})
        })
        .collect();
    Ok(Json(json!({
        "keyGen": org["key_gen"], "rotateDue": org["rotate_due"].as_i64().unwrap_or(0) == 1,
        "publicKey": org["public_key"], "privateKey": org["private_key"], "checkpoint": org["log_checkpoint"], "pins": org["member_pins"],
        "members": rows(&db, MEMBERS, &org_id).await?.iter().map(|m| json!({
            "id": m["id"], "userId": m["user_id"], "email": m["email"], "status": m["status"], "hasKey": m["akey"].is_string(),
            "publicKey": m["public_key"], "resetPasswordKey": m["reset_password_key"]})).collect::<Vec<_>>(),
        "collections": rows(&db, COLLECTIONS, &org_id).await?,
        "ciphers": ciphers,
        "attachments": rows(&db, FILES, &org_id).await?.iter().map(|a| json!({
            "id": a["id"], "cipherId": a["cipher_id"], "fileName": a["file_name"], "key": a["akey"]})).collect::<Vec<_>>(),
        "pendingUploads": rows(&db, PENDING, &org_id).await?.len(),
    })))
}

/// PUT /api/organizations/{org_id}/azet/pins {value} — the fingerprints the organizer's device has checked, sealed
/// with the vault key (the server cannot read or forge them).
#[worker::send]
pub async fn set_pins(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    organizer(&db, &org_id, &claims.sub).await?;
    key_current(&db, Some(&org_id), &claims.device).await?;
    let value = sealed(&p, "value")?;
    d1_query!(&db, "UPDATE organizations SET member_pins = ?1 WHERE id = ?2", value, org_id).map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

/// The ids in a request list, each exactly once, against the ids the database holds: equal or 400.
fn same_set(what: &str, sent: &[Value], held: &[Value]) -> Result<(), AppError> {
    let ids = |list: &[Value]| list.iter().filter_map(|x| text(x, "id")).collect::<HashSet<_>>();
    if sent.len() != held.len() || ids(sent).len() != sent.len() || ids(sent) != ids(held) {
        return Err(bad(&format!("{what} changed since they were read, or some are missing. Nothing was changed; start again.")));
    }
    Ok(())
}

fn list<'a>(p: &'a Value, k: &str) -> &'a [Value] {
    p.get(k).and_then(|x| x.as_array()).map(Vec::as_slice).unwrap_or(&[])
}

/// POST /api/organizations/{org_id}/azet/rotate-key
/// {keyGen, keys: {publicKey, encryptedPrivateKey}, checkpoint, members: [{id, key, resetPasswordKey}],
///  collections: [{id, name}], ciphers: [{id, updatedAt, cipher}], attachments: [{id, fileName, key}]}
/// A member sent with `key: null` (no public key to wrap to) loses the vault key and is handed it again by a
/// fingerprint confirm, like a new member.
#[worker::send]
pub async fn rotate(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let caller = organizer(&db, &org_id, &claims.sub).await?;
    let gen = generation(&db, &org_id).await?;
    if p.get("keyGen").and_then(|x| x.as_i64()) != Some(gen) {
        return Err(bad("The key of this vault was already changed by someone else. Nothing was changed; start again."));
    }
    if !rows(&db, PENDING, &org_id).await?.is_empty() {
        return Err(bad("A file is still being uploaded to this vault. Nothing was changed; try again in a minute."));
    }
    let keys = p.get("keys").cloned().unwrap_or(Value::Null);
    let public_key = text(&keys, "publicKey").filter(|k| !k.is_empty()).ok_or_else(|| bad("keys.publicKey"))?;
    let private_key = sealed(&keys, "encryptedPrivateKey")?;
    let checkpoint = match p.get("checkpoint") {
        None | Some(Value::Null) => None,
        Some(_) => Some(sealed(&p, "checkpoint")?),
    };
    let pins = sealed(&p, "pins")?;

    let (members, collections, ciphers, files) = (
        rows(&db, MEMBERS, &org_id).await?,
        rows(&db, COLLECTIONS, &org_id).await?,
        rows(&db, CIPHERS, &org_id).await?,
        rows(&db, FILES, &org_id).await?,
    );
    same_set("Members", list(&p, "members"), &members)?;
    same_set("Vaults", list(&p, "collections"), &collections)?;
    same_set("Items", list(&p, "ciphers"), &ciphers)?;
    same_set("Files", list(&p, "attachments"), &files)?;

    let now = db::now_string();
    let mut batch = vec![d1_query!(
        &db,
        "UPDATE organizations SET public_key = ?1, private_key = ?2, log_checkpoint = ?3, key_gen = key_gen + 1, rotate_due = 0, updated_at = ?4, member_pins = ?6 WHERE id = ?5",
        public_key, private_key, checkpoint, now, org_id, pins
    )
    .map_err(|_| AppError::Database)?];

    let mut caller_keeps_key = false;
    for m in list(&p, "members") {
        let id = text(m, "id").unwrap_or_default();
        let key = match m.get("key") {
            None | Some(Value::Null) => None,
            Some(_) => Some(sealed(m, "key")?),
        };
        let recovery = match m.get("resetPasswordKey") {
            None | Some(Value::Null) => None,
            Some(_) => Some(sealed(m, "resetPasswordKey")?),
        };
        caller_keeps_key |= key.is_some() && caller["id"].as_str() == Some(id.as_str());
        // Without the new key a confirmed member goes back to "joined, key check needed"; a suspended one stays suspended.
        batch.push(
            d1_query!(
                &db,
                "UPDATE org_members SET akey = ?1, reset_password_key = CASE WHEN reset_password_key IS NULL THEN NULL ELSE ?2 END, status = CASE WHEN ?1 IS NULL AND status = 2 THEN 1 ELSE status END, updated_at = ?3 WHERE id = ?4 AND org_id = ?5",
                key, recovery, now, id, org_id
            )
            .map_err(|_| AppError::Database)?,
        );
    }
    if !caller_keeps_key {
        return Err(bad("The organizer's own key is missing"));
    }
    for c in list(&p, "collections") {
        let name = sealed(c, "name")?;
        batch.push(
            d1_query!(&db, "UPDATE collections SET name = ?1, updated_at = ?2 WHERE id = ?3 AND org_id = ?4", name, now, text(c, "id"), org_id)
                .map_err(|_| AppError::Database)?,
        );
    }
    let seen_at: HashMap<String, String> = ciphers.iter().filter_map(|c| Some((text(c, "id")?, text(c, "updated_at")?))).collect();
    for c in list(&p, "ciphers") {
        let id = text(c, "id").unwrap_or_default();
        // An item someone saved after the organizer's device read it would be overwritten with its older contents.
        if text(c, "updatedAt") != seen_at.get(&id).cloned() {
            return Err(bad("An item was changed while the key was being changed. Nothing was changed; start again."));
        }
        // The same shape the database holds (what `rotation` returned), checked like any saved item: ciphertext only.
        let stored: CipherData = serde_json::from_value(c.get("cipher").cloned().unwrap_or(Value::Null)).map_err(|e| bad(&format!("cipher: {e}")))?;
        let data = serde_json::to_string(&CipherData::new(stored.name, stored.notes, stored.type_fields)?).map_err(|_| AppError::Internal)?;
        batch.push(
            d1_query!(&db, "UPDATE ciphers SET data = ?1, updated_at = ?2 WHERE id = ?3 AND organization_id = ?4", data, now, id, org_id)
                .map_err(|_| AppError::Database)?,
        );
    }
    for a in list(&p, "attachments") {
        let (file_name, key) = (sealed(a, "fileName")?, sealed(a, "key")?);
        batch.push(
            d1_query!(&db, "UPDATE attachments SET file_name = ?1, akey = ?2, updated_at = ?3 WHERE id = ?4", file_name, key, now, text(a, "id"))
                .map_err(|_| AppError::Database)?,
        );
    }
    // Every device has to sync before it writes again; the organizer's device made the key, so it holds it already.
    batch.push(d1_query!(&db, "DELETE FROM org_key_seen WHERE org_id = ?1", org_id).map_err(|_| AppError::Database)?);
    batch.push(
        d1_query!(&db, "INSERT INTO org_key_seen (device, org_id, gen) VALUES (?1, ?2, ?3)", claims.device, org_id, gen + 1)
            .map_err(|_| AppError::Database)?,
    );
    db.batch(batch).await?;

    log_event(&db, &org_id, caller["id"].as_str().unwrap_or_default(), "rotate", None, list(&p, "ciphers").len() as i64, None).await?;
    touch_org_users(&env, &db, &org_id).await?; // after the change: whoever syncs now receives the new key
    Ok(Json(json!({"keyGen": gen + 1, "items": list(&p, "ciphers").len(), "members": list(&p, "members").len()})))
}
