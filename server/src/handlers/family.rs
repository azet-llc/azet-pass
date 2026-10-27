//! AZET Pass families on Bitwarden's organization wire shape: an organization is a family (5 seats), a collection is
//! a shared vault, a member is a family member (owner/admin = family organizer, guest = one shared vault only).
//! Every key here arrives wrapped by a client; the server checks who may read or change what and never unwraps.
use axum::extract::{Path, State};
use axum::Json;
use serde_json::{json, Value};
use std::sync::Arc;
use uuid::Uuid;
use worker::Env;

use crate::auth::Claims;
use crate::d1_query;
use crate::db;
use crate::error::AppError;

const OWNER: i64 = 0;
const ADMIN: i64 = 1;
const MEMBER: i64 = 2;
const GUEST: i64 = 5;
const INVITED: i64 = 0;
const ACCEPTED: i64 = 1;
const CONFIRMED: i64 = 2;
const REVOKED: i64 = -1;

fn bad(msg: &str) -> AppError {
    AppError::BadRequest(msg.to_string())
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(|x| x.to_string())
}

fn i(v: &Value, k: &str) -> i64 {
    v.get(k).and_then(|x| x.as_i64()).unwrap_or(0)
}

fn b(v: &Value, k: &str) -> bool {
    v.get(k).and_then(|x| x.as_bool()).unwrap_or(false)
}

fn token() -> Result<String, AppError> {
    let mut buf = [0u8; 24];
    getrandom::fill(&mut buf).map_err(|_| AppError::Internal)?;
    Ok(buf.iter().map(|x| format!("{x:02x}")).collect())
}

async fn member_row(db: &db::Db, org_id: &str, user_id: &str) -> Result<Option<Value>, AppError> {
    Ok(db
        .prepare("SELECT * FROM org_members WHERE org_id = ?1 AND user_id = ?2")
        .bind(&[org_id.into(), user_id.into()])?
        .first(None)
        .await?)
}

/// The caller's confirmed membership, or 404 so outsiders cannot probe family ids.
async fn me(db: &db::Db, org_id: &str, user_id: &str) -> Result<Value, AppError> {
    match member_row(db, org_id, user_id).await? {
        Some(m) if i(&m, "status") == CONFIRMED => Ok(m),
        _ => Err(AppError::NotFound("Organization not found".into())),
    }
}

async fn organizer(db: &db::Db, org_id: &str, user_id: &str) -> Result<Value, AppError> {
    let m = me(db, org_id, user_id).await?;
    if i(&m, "type") > ADMIN {
        return Err(AppError::Unauthorized("Only a family organizer can do this".into()));
    }
    Ok(m)
}

async fn target(db: &db::Db, org_id: &str, member_id: &str) -> Result<Value, AppError> {
    db.prepare("SELECT * FROM org_members WHERE id = ?1 AND org_id = ?2")
        .bind(&[member_id.into(), org_id.into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::NotFound("Member not found".into()))
}

async fn touch_org_users(db: &db::Db, org_id: &str) -> Result<(), AppError> {
    // clients resync when their account revision moves
    d1_query!(db, "UPDATE users SET updated_at = ?1 WHERE id IN (SELECT user_id FROM org_members WHERE org_id = ?2 AND user_id IS NOT NULL)", db::now_string(), org_id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(())
}

async fn set_member_collections(db: &db::Db, org_id: &str, member_id: &str, cols: &Value) -> Result<(), AppError> {
    d1_query!(db, "DELETE FROM collection_members WHERE member_id = ?1", member_id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    for c in cols.as_array().cloned().unwrap_or_default() {
        let cid = s(&c, "id").ok_or_else(|| bad("collection id"))?;
        d1_query!(db, "INSERT INTO collection_members (collection_id, member_id, read_only, hide_passwords, manage)
             SELECT id, ?2, ?3, ?4, ?5 FROM collections WHERE id = ?1 AND org_id = ?6",
            cid, member_id, b(&c, "readOnly") as i64, b(&c, "hidePasswords") as i64, b(&c, "manage") as i64, org_id)
            .map_err(|_| AppError::Database)?
            .run()
            .await?;
    }
    Ok(())
}

fn org_json(org: &Value, m: &Value) -> Value {
    let t = i(m, "type");
    json!({
        "object": "profileOrganization",
        "id": org["id"], "name": org["name"], "key": m["akey"], "userId": m["user_id"],
        "organizationUserId": m["id"],
        "status": i(m, "status"), "type": if t == GUEST { MEMBER } else { t }, "azetRole": t,
        "enabled": true, "seats": org["seats"], "maxCollections": null, "maxStorageGb": 1,
        "usePolicies": false, "useGroups": false, "useDirectory": false, "useEvents": false, "useTotp": true,
        "use2fa": true, "useApi": false, "useSso": false, "useKeyConnector": false, "useScim": false,
        "useResetPassword": true, "useCustomPermissions": false, "useActivateAutofillPolicy": false,
        "useSecretsManager": false, "usePasswordManager": true, "useOrganizationDomains": false,
        "selfHost": true, "usersGetPremium": true, "hasPublicAndPrivateKeys": org["public_key"].is_string(),
        "resetPasswordEnrolled": m["reset_password_key"].is_string(), "planProductType": 1, "productTierType": 1,
        "keyConnectorEnabled": false, "keyConnectorUrl": null, "ssoBound": false, "identifier": null,
        "familySponsorshipAvailable": false, "familySponsorshipFriendlyName": null, "accessSecretsManager": false,
        "limitCollectionCreation": t > ADMIN, "limitCollectionDeletion": t > ADMIN,
        "allowAdminAccessToAllCollectionItems": true, "userIsManagedByOrganization": false,
        "permissions": {
            "accessEventLogs": false, "accessImportExport": t <= ADMIN, "accessReports": t <= ADMIN,
            "createNewCollections": t <= ADMIN, "editAnyCollection": t <= ADMIN, "deleteAnyCollection": t <= ADMIN,
            "manageGroups": false, "managePolicies": false, "manageSso": false, "manageUsers": t <= ADMIN,
            "manageResetPassword": t <= ADMIN, "manageScim": false
        }
    })
}

/// `profile.organizations` for /api/sync and /api/accounts/profile.
pub async fn profile_organizations(db: &db::Db, user_id: &str) -> Result<Vec<Value>, AppError> {
    let rows: Vec<Value> = db
        .prepare("SELECT m.*, o.name AS o_name, o.seats AS o_seats, o.public_key AS o_public_key FROM org_members m JOIN organizations o ON o.id = m.org_id WHERE m.user_id = ?1 AND m.status != ?2")
        .bind(&[user_id.into(), (REVOKED as f64).into()])?
        .all()
        .await?
        .results()?;
    Ok(rows
        .iter()
        .map(|m| {
            let org = json!({"id": m["org_id"], "name": m["o_name"], "seats": m["o_seats"], "public_key": m["o_public_key"]});
            org_json(&org, m)
        })
        .collect())
}

/// `collections` for /api/sync: every shared vault the user can open.
pub async fn sync_collections(db: &db::Db, user_id: &str) -> Result<Vec<Value>, AppError> {
    let rows: Vec<Value> = db
        .prepare(
            "SELECT c.id, c.org_id, c.name, c.travel_safe, 0 AS read_only, 0 AS hide_passwords, 1 AS manage
               FROM collections c JOIN org_members m ON m.org_id = c.org_id
              WHERE m.user_id = ?1 AND m.status = 2 AND m.access_all = 1
             UNION
             SELECT c.id, c.org_id, c.name, c.travel_safe, cm.read_only, cm.hide_passwords, cm.manage
               FROM collections c JOIN collection_members cm ON cm.collection_id = c.id
               JOIN org_members m ON m.id = cm.member_id
              WHERE m.user_id = ?1 AND m.status = 2 AND m.access_all = 0",
        )
        .bind(&[user_id.into()])?
        .all()
        .await?
        .results()?;
    Ok(rows.iter().map(collection_json).collect())
}

fn collection_json(c: &Value) -> Value {
    json!({
        "object": "collectionDetails", "id": c["id"], "organizationId": c["org_id"], "name": c["name"],
        "externalId": null, "type": 0, "readOnly": i(c, "read_only") == 1, "hidePasswords": i(c, "hide_passwords") == 1,
        "manage": i(c, "manage") == 1, "travelSafe": i(c, "travel_safe") == 1
    })
}

/// POST /api/organizations — a family with its first shared vault; the caller becomes the owner.
#[worker::send]
pub async fn create(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let name = s(&p, "name").ok_or_else(|| bad("name"))?;
    let key = s(&p, "key").ok_or_else(|| bad("key"))?;
    let keys = p.get("keys").cloned().unwrap_or(Value::Null);
    let owned: Option<Value> = db
        .prepare("SELECT 1 FROM org_members WHERE user_id = ?1 AND type = 0 AND status = 2")
        .bind(&[claims.sub.clone().into()])?
        .first(None)
        .await?;
    if owned.is_some() {
        return Err(bad("You already organize a family"));
    }
    let now = db::now_string();
    let org_id = Uuid::new_v4().to_string();
    let member_id = Uuid::new_v4().to_string();
    d1_query!(&db, "INSERT INTO organizations (id, name, billing_email, public_key, private_key, seats, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 5, ?6, ?6)",
        org_id, name, s(&p, "billingEmail").unwrap_or(claims.email.clone()), s(&keys, "publicKey"), s(&keys, "encryptedPrivateKey"), now)
        .map_err(|_| AppError::Database)?.run().await?;
    d1_query!(&db, "INSERT INTO org_members (id, org_id, user_id, email, display_name, status, type, access_all, akey, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 2, 0, 1, ?6, ?7, ?7)",
        member_id, org_id, claims.sub, claims.email.to_lowercase(), claims.name, key, now)
        .map_err(|_| AppError::Database)?.run().await?;
    if let Some(col) = s(&p, "collectionName") {
        d1_query!(&db, "INSERT INTO collections (id, org_id, name, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?4)",
            Uuid::new_v4().to_string(), org_id, col, now)
            .map_err(|_| AppError::Database)?.run().await?;
    }
    db::touch_user_updated_at(&db, &claims.sub, &now).await?;
    let org: Value = db.prepare("SELECT * FROM organizations WHERE id = ?1").bind(&[org_id.clone().into()])?.first(None).await?.ok_or(AppError::Internal)?;
    let m = target(&db, &org_id, &member_id).await?;
    Ok(Json(org_json(&org, &m)))
}

/// GET /api/organizations/{org_id}
#[worker::send]
pub async fn get(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let m = me(&db, &org_id, &claims.sub).await?;
    let org: Value = db.prepare("SELECT * FROM organizations WHERE id = ?1").bind(&[org_id.into()])?.first(None).await?.ok_or(AppError::Internal)?;
    Ok(Json(org_json(&org, &m)))
}

/// PUT /api/organizations/{org_id} — rename the family.
#[worker::send]
pub async fn rename(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    organizer(&db, &org_id, &claims.sub).await?;
    let name = s(&p, "name").ok_or_else(|| bad("name"))?;
    d1_query!(&db, "UPDATE organizations SET name = ?1, updated_at = ?2 WHERE id = ?3", name, db::now_string(), org_id)
        .map_err(|_| AppError::Database)?.run().await?;
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({})))
}

/// GET /api/organizations/{org_id}/keys — org public key and the org-key-wrapped private key.
#[worker::send]
pub async fn keys(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    me(&db, &org_id, &claims.sub).await?;
    let org: Value = db.prepare("SELECT public_key, private_key FROM organizations WHERE id = ?1").bind(&[org_id.into()])?.first(None).await?.ok_or(AppError::Internal)?;
    Ok(Json(json!({"object": "organizationKeys", "publicKey": org["public_key"], "privateKey": org["private_key"]})))
}

/// GET /api/organizations/{org_id}/public-key — what a joining member wraps their recovery key with.
#[worker::send]
pub async fn public_key(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    if member_row(&db, &org_id, &claims.sub).await?.is_none() {
        return Err(AppError::NotFound("Organization not found".into()));
    }
    let org: Value = db.prepare("SELECT public_key FROM organizations WHERE id = ?1").bind(&[org_id.into()])?.first(None).await?.ok_or(AppError::Internal)?;
    Ok(Json(json!({"object": "organizationPublicKey", "publicKey": org["public_key"]})))
}

/// GET /api/organizations/{org_id}/users — the family list (organizers see invite tokens to resend links).
#[worker::send]
pub async fn members(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let caller = me(&db, &org_id, &claims.sub).await?;
    let is_org = i(&caller, "type") <= ADMIN;
    let rows: Vec<Value> = db
        .prepare("SELECT m.*, u.name AS u_name, u.public_key AS u_public_key FROM org_members m LEFT JOIN users u ON u.id = m.user_id WHERE m.org_id = ?1 ORDER BY m.type, m.created_at")
        .bind(&[org_id.clone().into()])?
        .all()
        .await?
        .results()?;
    let mut data = Vec::new();
    for m in rows {
        let cols: Vec<Value> = db
            .prepare("SELECT collection_id AS id, read_only, hide_passwords, manage FROM collection_members WHERE member_id = ?1")
            .bind(&[m["id"].as_str().unwrap_or_default().into()])?
            .all()
            .await?
            .results()?;
        data.push(json!({
            "object": "organizationUserUserDetails", "id": m["id"], "userId": m["user_id"], "email": m["email"],
            "name": m["u_name"].as_str().or(m["display_name"].as_str()), "displayName": m["display_name"],
            "status": i(&m, "status"), "type": if i(&m, "type") == GUEST { MEMBER } else { i(&m, "type") }, "azetRole": i(&m, "type"),
            "accessAll": i(&m, "access_all") == 1, "resetPasswordEnrolled": m["reset_password_key"].is_string(),
            "publicKey": if i(&m, "status") == ACCEPTED { m["u_public_key"].clone() } else { Value::Null },
            "inviteToken": if is_org && i(&m, "status") == INVITED { m["invite_token"].clone() } else { Value::Null },
            "createdAt": m["created_at"],
            "collections": cols.iter().map(|c| json!({"id": c["id"], "readOnly": i(c, "read_only") == 1, "hidePasswords": i(c, "hide_passwords") == 1, "manage": i(c, "manage") == 1})).collect::<Vec<_>>()
        }));
    }
    Ok(Json(json!({"object": "list", "data": data, "continuationToken": null})))
}

/// POST /api/organizations/{org_id}/users/invite {emails, type, accessAll, collections, displayName}
/// There is no invite mail: the response carries the link token the organizer sends themselves (KakaoTalk, SMS).
#[worker::send]
pub async fn invite(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let caller = organizer(&db, &org_id, &claims.sub).await?;
    let t = i(&p, "type");
    if !(t == ADMIN || t == MEMBER || t == GUEST || (t == OWNER && i(&caller, "type") == OWNER)) {
        return Err(bad("type"));
    }
    let emails: Vec<String> = p.get("emails").and_then(|e| e.as_array()).cloned().unwrap_or_default().iter().filter_map(|e| e.as_str().map(|x| x.trim().to_lowercase())).collect();
    if emails.is_empty() {
        return Err(bad("emails"));
    }
    let used: Value = db.prepare("SELECT COUNT(*) AS n, (SELECT seats FROM organizations WHERE id = ?1) AS seats FROM org_members WHERE org_id = ?1 AND type != 5").bind(&[org_id.clone().into()])?.first(None).await?.ok_or(AppError::Internal)?;
    if t != GUEST && i(&used, "n") + emails.len() as i64 > i(&used, "seats") {
        return Err(bad("A family has 5 people. Remove someone or invite as a guest."));
    }
    let now = db::now_string();
    let access_all = (t <= ADMIN || b(&p, "accessAll")) as i64;
    let mut out = Vec::new();
    for email in emails {
        let id = Uuid::new_v4().to_string();
        let tok = token()?;
        d1_query!(&db, "INSERT INTO org_members (id, org_id, email, display_name, status, type, access_all, invite_token, invited_by, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, 0, ?5, ?6, ?7, ?8, ?9, ?9)",
            id, org_id, email, s(&p, "displayName"), t, access_all, tok, claims.sub, now)
            .map_err(|_| bad("Already invited"))?.run().await.map_err(|_| bad("Already invited"))?;
        if let Some(cols) = p.get("collections") {
            set_member_collections(&db, &org_id, &id, cols).await?;
        }
        out.push(json!({"id": id, "email": email, "token": tok}));
    }
    Ok(Json(json!({"object": "list", "data": out})))
}

/// POST /api/organizations/{org_id}/users/{member_id}/reinvite — a fresh link (the old one stops working).
#[worker::send]
pub async fn reinvite(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    organizer(&db, &org_id, &claims.sub).await?;
    let tok = token()?;
    d1_query!(&db, "UPDATE org_members SET invite_token = ?1, updated_at = ?2 WHERE id = ?3 AND org_id = ?4 AND status = 0", tok, db::now_string(), member_id, org_id)
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({"id": member_id, "token": tok})))
}

/// GET /api/azet/invites/{member_id}?token= — what the invite link shows before sign-in (family and inviter name).
#[worker::send]
pub async fn invite_preview(State(env): State<Arc<Env>>, Path((member_id, tok)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let row: Value = db
        .prepare("SELECT m.org_id, m.email, m.display_name, m.type, o.name AS org_name, u.name AS inviter FROM org_members m JOIN organizations o ON o.id = m.org_id LEFT JOIN users u ON u.id = m.invited_by WHERE m.id = ?1 AND m.invite_token = ?2 AND m.status = 0")
        .bind(&[member_id.into(), tok.into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::NotFound("This invite link has expired. Ask for a new one.".into()))?;
    Ok(Json(json!({"organizationId": row["org_id"], "email": row["email"], "displayName": row["display_name"], "organizationName": row["org_name"], "invitedBy": row["inviter"], "type": row["type"]})))
}

/// POST /api/organizations/{org_id}/users/{member_id}/accept {token, resetPasswordKey}
/// The signed-in account must own the invited email. Recovery enrolment comes with joining (1Password Families: an
/// organizer can always help a member back in).
#[worker::send]
pub async fn accept(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let m = target(&db, &org_id, &member_id).await?;
    if i(&m, "status") != INVITED || s(&m, "invite_token") != s(&p, "token") || s(&p, "token").is_none() {
        return Err(bad("This invite link has expired. Ask for a new one."));
    }
    if s(&m, "email").unwrap_or_default() != claims.email.to_lowercase() {
        return Err(bad("This invite is for another email address"));
    }
    if member_row(&db, &org_id, &claims.sub).await?.is_some() {
        return Err(bad("Already in this family"));
    }
    d1_query!(&db, "UPDATE org_members SET user_id = ?1, status = 1, invite_token = NULL, reset_password_key = ?2, updated_at = ?3 WHERE id = ?4",
        claims.sub, s(&p, "resetPasswordKey"), db::now_string(), member_id)
        .map_err(|_| AppError::Database)?.run().await?;
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({})))
}

/// POST /api/organizations/{org_id}/users/{member_id}/confirm {key} — the organizer, after comparing the
/// fingerprint words with the member, hands over the family key wrapped to the member's public key.
#[worker::send]
pub async fn confirm(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    organizer(&db, &org_id, &claims.sub).await?;
    let m = target(&db, &org_id, &member_id).await?;
    if i(&m, "status") != ACCEPTED {
        return Err(bad("Member has not accepted the invite yet"));
    }
    let key = s(&p, "key").ok_or_else(|| bad("key"))?;
    d1_query!(&db, "UPDATE org_members SET akey = ?1, status = 2, updated_at = ?2 WHERE id = ?3", key, db::now_string(), member_id)
        .map_err(|_| AppError::Database)?.run().await?;
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({})))
}

/// PUT /api/organizations/{org_id}/users/{member_id} {type, accessAll, collections}
#[worker::send]
pub async fn update_member(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let caller = organizer(&db, &org_id, &claims.sub).await?;
    let m = target(&db, &org_id, &member_id).await?;
    let t = p.get("type").and_then(|x| x.as_i64()).unwrap_or(i(&m, "type"));
    if (i(&m, "type") == OWNER || t == OWNER) && i(&caller, "type") != OWNER {
        return Err(AppError::Unauthorized("Only the family owner can change an owner".into()));
    }
    if i(&m, "type") == OWNER && t != OWNER {
        let owners: Value = db.prepare("SELECT COUNT(*) AS n FROM org_members WHERE org_id = ?1 AND type = 0 AND status = 2").bind(&[org_id.clone().into()])?.first(None).await?.ok_or(AppError::Internal)?;
        if i(&owners, "n") <= 1 {
            return Err(bad("A family needs at least one owner"));
        }
    }
    let access_all = (t <= ADMIN || b(&p, "accessAll")) as i64;
    d1_query!(&db, "UPDATE org_members SET type = ?1, access_all = ?2, updated_at = ?3 WHERE id = ?4", t, access_all, db::now_string(), member_id)
        .map_err(|_| AppError::Database)?.run().await?;
    if let Some(cols) = p.get("collections") {
        set_member_collections(&db, &org_id, &member_id, cols).await?;
    }
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({})))
}

async fn set_status(env: &Env, claims: &Claims, org_id: &str, member_id: &str, status: i64) -> Result<Json<Value>, AppError> {
    let db = db::get_db(env)?;
    let caller = organizer(&db, org_id, &claims.sub).await?;
    let m = target(&db, org_id, member_id).await?;
    if s(&m, "user_id").as_deref() == Some(claims.sub.as_str()) || (i(&m, "type") == OWNER && i(&caller, "type") != OWNER) {
        return Err(AppError::Unauthorized("Not allowed".into()));
    }
    // restore puts a member back to "accepted" when they never had the key, otherwise straight to confirmed
    let next = if status == REVOKED { REVOKED } else if m["akey"].is_string() { CONFIRMED } else { ACCEPTED };
    d1_query!(&db, "UPDATE org_members SET status = ?1, updated_at = ?2 WHERE id = ?3", next, db::now_string(), member_id)
        .map_err(|_| AppError::Database)?.run().await?;
    touch_org_users(&db, org_id).await?;
    Ok(Json(json!({})))
}

/// PUT /api/organizations/{org_id}/users/{member_id}/revoke — suspend (1Password: suspend a family member).
#[worker::send]
pub async fn revoke(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    set_status(&env, &claims, &org_id, &member_id, REVOKED).await
}

/// PUT /api/organizations/{org_id}/users/{member_id}/restore
#[worker::send]
pub async fn restore(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    set_status(&env, &claims, &org_id, &member_id, CONFIRMED).await
}

/// DELETE /api/organizations/{org_id}/users/{member_id}
#[worker::send]
pub async fn remove(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let caller = organizer(&db, &org_id, &claims.sub).await?;
    let m = target(&db, &org_id, &member_id).await?;
    if i(&m, "type") == OWNER && i(&caller, "type") != OWNER {
        return Err(AppError::Unauthorized("Not allowed".into()));
    }
    if s(&m, "user_id").as_deref() == Some(claims.sub.as_str()) {
        return Err(bad("Use leave to remove yourself"));
    }
    touch_org_users(&db, &org_id).await?;
    d1_query!(&db, "DELETE FROM org_members WHERE id = ?1", member_id).map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

/// POST /api/organizations/{org_id}/leave
#[worker::send]
pub async fn leave(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let m = member_row(&db, &org_id, &claims.sub).await?.ok_or_else(|| AppError::NotFound("Organization not found".into()))?;
    if i(&m, "type") == OWNER {
        let owners: Value = db.prepare("SELECT COUNT(*) AS n FROM org_members WHERE org_id = ?1 AND type = 0 AND status = 2").bind(&[org_id.clone().into()])?.first(None).await?.ok_or(AppError::Internal)?;
        if i(&owners, "n") <= 1 {
            return Err(bad("Make someone else the owner before leaving"));
        }
    }
    d1_query!(&db, "DELETE FROM org_members WHERE id = ?1", s(&m, "id")).map_err(|_| AppError::Database)?.run().await?;
    db::touch_user_updated_at(&db, &claims.sub, &db::now_string()).await?;
    Ok(Json(json!({})))
}

/// GET /api/users/{user_id}/public-key — only for people who share a family with the caller.
#[worker::send]
pub async fn user_public_key(claims: Claims, State(env): State<Arc<Env>>, Path(user_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let row: Value = db
        .prepare("SELECT u.public_key FROM users u WHERE u.id = ?1 AND (u.id = ?2 OR EXISTS (SELECT 1 FROM org_members a JOIN org_members b ON a.org_id = b.org_id WHERE a.user_id = ?1 AND b.user_id = ?2 AND b.status = 2))")
        .bind(&[user_id.clone().into(), claims.sub.into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::NotFound("User not found".into()))?;
    Ok(Json(json!({"object": "userKey", "userId": user_id, "publicKey": row["public_key"]})))
}

/// GET /api/organizations/{org_id}/collections
#[worker::send]
pub async fn collections(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    me(&db, &org_id, &claims.sub).await?;
    let all = sync_collections(&db, &claims.sub).await?;
    let data: Vec<Value> = all.into_iter().filter(|c| c["organizationId"].as_str() == Some(org_id.as_str())).collect();
    Ok(Json(json!({"object": "list", "data": data, "continuationToken": null})))
}

async fn write_collection(db: &db::Db, org_id: &str, cid: &str, p: &Value) -> Result<(), AppError> {
    if let Some(users) = p.get("users").and_then(|u| u.as_array()) {
        d1_query!(db, "DELETE FROM collection_members WHERE collection_id = ?1", cid).map_err(|_| AppError::Database)?.run().await?;
        for u in users {
            let mid = s(u, "id").ok_or_else(|| bad("user id"))?;
            d1_query!(db, "INSERT INTO collection_members (collection_id, member_id, read_only, hide_passwords, manage) SELECT ?1, id, ?3, ?4, ?5 FROM org_members WHERE id = ?2 AND org_id = ?6",
                cid, mid, b(u, "readOnly") as i64, b(u, "hidePasswords") as i64, b(u, "manage") as i64, org_id)
                .map_err(|_| AppError::Database)?.run().await?;
        }
    }
    touch_org_users(db, org_id).await
}

/// POST /api/organizations/{org_id}/collections {name, users:[{id, readOnly}], travelSafe}
#[worker::send]
pub async fn create_collection(claims: Claims, State(env): State<Arc<Env>>, Path(org_id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let caller = me(&db, &org_id, &claims.sub).await?;
    if i(&caller, "type") == GUEST {
        return Err(AppError::Unauthorized("Guests cannot create vaults".into()));
    }
    let cid = Uuid::new_v4().to_string();
    let now = db::now_string();
    let name = s(&p, "name").ok_or_else(|| bad("name"))?;
    d1_query!(&db, "INSERT INTO collections (id, org_id, name, travel_safe, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
        cid, org_id, name, b(&p, "travelSafe") as i64, now)
        .map_err(|_| AppError::Database)?.run().await?;
    // a member who makes a vault can always open and manage it
    if i(&caller, "access_all") == 0 {
        let mut p2 = p.clone();
        let mut users = p.get("users").and_then(|u| u.as_array()).cloned().unwrap_or_default();
        users.retain(|u| u["id"] != caller["id"]);
        users.push(json!({"id": caller["id"], "readOnly": false, "manage": true}));
        p2["users"] = Value::Array(users);
        write_collection(&db, &org_id, &cid, &p2).await?;
    } else {
        write_collection(&db, &org_id, &cid, &p).await?;
    }
    let c: Value = db.prepare("SELECT *, 0 AS read_only, 0 AS hide_passwords, 1 AS manage FROM collections WHERE id = ?1").bind(&[cid.into()])?.first(None).await?.ok_or(AppError::Internal)?;
    Ok(Json(collection_json(&c)))
}

async fn may_manage(db: &db::Db, org_id: &str, cid: &str, user_id: &str) -> Result<(), AppError> {
    let m = me(db, org_id, user_id).await?;
    if i(&m, "type") <= ADMIN {
        return Ok(());
    }
    let ok: Option<Value> = db.prepare("SELECT 1 FROM collection_members WHERE collection_id = ?1 AND member_id = ?2 AND manage = 1").bind(&[cid.into(), m["id"].as_str().unwrap_or_default().into()])?.first(None).await?;
    ok.map(|_| ()).ok_or_else(|| AppError::Unauthorized("You cannot manage this vault".into()))
}

/// PUT /api/organizations/{org_id}/collections/{cid}
#[worker::send]
pub async fn update_collection(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, cid)): Path<(String, String)>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    may_manage(&db, &org_id, &cid, &claims.sub).await?;
    d1_query!(&db, "UPDATE collections SET name = COALESCE(?1, name), travel_safe = COALESCE(?2, travel_safe), updated_at = ?3 WHERE id = ?4 AND org_id = ?5",
        s(&p, "name"), p.get("travelSafe").and_then(|x| x.as_bool()).map(|x| x as i64), db::now_string(), cid, org_id)
        .map_err(|_| AppError::Database)?.run().await?;
    write_collection(&db, &org_id, &cid, &p).await?;
    Ok(Json(json!({"id": cid})))
}

/// DELETE /api/organizations/{org_id}/collections/{cid} — its items move to the trash of nobody: they are deleted
/// with the vault like in 1Password, so the app asks first.
#[worker::send]
pub async fn delete_collection(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, cid)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    may_manage(&db, &org_id, &cid, &claims.sub).await?;
    d1_query!(&db, "DELETE FROM ciphers WHERE organization_id = ?1 AND id IN (SELECT cipher_id FROM collection_ciphers WHERE collection_id = ?2) AND id NOT IN (SELECT cipher_id FROM collection_ciphers WHERE collection_id != ?2)", org_id, cid)
        .map_err(|_| AppError::Database)?.run().await?;
    d1_query!(&db, "DELETE FROM collections WHERE id = ?1 AND org_id = ?2", cid, org_id).map_err(|_| AppError::Database)?.run().await?;
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({})))
}

/// Checks that the user may put items into every listed collection of the organization.
pub async fn check_collections_writable(db: &db::Db, org_id: &str, user_id: &str, ids: &[String]) -> Result<(), AppError> {
    let m = me(db, org_id, user_id).await?;
    if ids.is_empty() {
        return Err(bad("Pick a shared vault"));
    }
    for cid in ids {
        let ok: Option<Value> = if i(&m, "access_all") == 1 {
            db.prepare("SELECT 1 FROM collections WHERE id = ?1 AND org_id = ?2").bind(&[cid.as_str().into(), org_id.into()])?.first(None).await?
        } else {
            db.prepare("SELECT 1 FROM collection_members cm JOIN collections c ON c.id = cm.collection_id WHERE cm.collection_id = ?1 AND c.org_id = ?2 AND cm.member_id = ?3 AND cm.read_only = 0")
                .bind(&[cid.as_str().into(), org_id.into(), m["id"].as_str().unwrap_or_default().into()])?.first(None).await?
        };
        if ok.is_none() {
            return Err(AppError::Unauthorized("You cannot add items to this vault".into()));
        }
    }
    Ok(())
}

pub async fn set_cipher_collections(db: &db::Db, cipher_id: &str, ids: &[String]) -> Result<(), AppError> {
    d1_query!(db, "DELETE FROM collection_ciphers WHERE cipher_id = ?1", cipher_id).map_err(|_| AppError::Database)?.run().await?;
    for cid in ids {
        d1_query!(db, "INSERT INTO collection_ciphers (collection_id, cipher_id) VALUES (?1, ?2)", cid, cipher_id).map_err(|_| AppError::Database)?.run().await?;
    }
    Ok(())
}

/// PUT /api/ciphers/{id}/share {cipher, collectionIds} — a personal item moves into a shared vault. The client has
/// already re-encrypted every field with the family key.
#[worker::send]
pub async fn share_cipher(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let cipher = p.get("cipher").cloned().ok_or_else(|| bad("cipher"))?;
    let org_id = s(&cipher, "organizationId").ok_or_else(|| bad("organizationId"))?;
    let ids: Vec<String> = p.get("collectionIds").and_then(|c| c.as_array()).cloned().unwrap_or_default().iter().filter_map(|x| x.as_str().map(String::from)).collect();
    check_collections_writable(&db, &org_id, &claims.sub, &ids).await?;
    let owned: Option<Value> = db.prepare("SELECT 1 FROM ciphers WHERE id = ?1 AND user_id = ?2 AND organization_id IS NULL").bind(&[id.clone().into(), claims.sub.clone().into()])?.first(None).await?;
    if owned.is_none() {
        return Err(AppError::NotFound("Cipher not found".into()));
    }
    let data = crate::models::cipher::CipherData::from_share_payload(&cipher)?;
    let now = db::now_string();
    d1_query!(&db, "UPDATE ciphers SET user_id = NULL, organization_id = ?1, data = ?2, folder_id = NULL, updated_at = ?3 WHERE id = ?4",
        org_id, data, now, id)
        .map_err(|_| AppError::Database)?.run().await?;
    set_cipher_collections(&db, &id, &ids).await?;
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({"id": id, "organizationId": org_id, "collectionIds": ids, "revisionDate": now})))
}

/// PUT|POST /api/ciphers/{id}/collections {collectionIds}
#[worker::send]
pub async fn cipher_collections(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let row: Value = db.prepare("SELECT organization_id FROM ciphers WHERE id = ?1 AND id IN (SELECT cipher_id FROM cipher_access WHERE user_id = ?2 AND can_edit = 1)")
        .bind(&[id.clone().into(), claims.sub.clone().into()])?.first(None).await?.ok_or_else(|| AppError::NotFound("Cipher not found".into()))?;
    let org_id = s(&row, "organization_id").ok_or_else(|| bad("Not a shared item"))?;
    let ids: Vec<String> = p.get("collectionIds").and_then(|c| c.as_array()).cloned().unwrap_or_default().iter().filter_map(|x| x.as_str().map(String::from)).collect();
    check_collections_writable(&db, &org_id, &claims.sub, &ids).await?;
    set_cipher_collections(&db, &id, &ids).await?;
    d1_query!(&db, "UPDATE ciphers SET updated_at = ?1 WHERE id = ?2", db::now_string(), id).map_err(|_| AppError::Database)?.run().await?;
    touch_org_users(&db, &org_id).await?;
    Ok(Json(json!({})))
}

/// PUT /api/organizations/{org_id}/users/{user_id}/reset-password-enrollment {resetPasswordKey, masterPasswordHash}
#[worker::send]
pub async fn enroll_recovery(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, user_id)): Path<(String, String)>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    if user_id != claims.sub {
        return Err(AppError::Unauthorized("Not allowed".into()));
    }
    let db = db::get_db(&env)?;
    let m = member_row(&db, &org_id, &claims.sub).await?.ok_or_else(|| AppError::NotFound("Organization not found".into()))?;
    let key = s(&p, "resetPasswordKey");
    if key.is_some() {
        crate::handlers::accounts::checked_user(&db, &claims.sub, &s(&p, "masterPasswordHash").unwrap_or_default()).await?;
    }
    d1_query!(&db, "UPDATE org_members SET reset_password_key = ?1, updated_at = ?2 WHERE id = ?3", key, db::now_string(), s(&m, "id"))
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

async fn recoverable(db: &db::Db, org_id: &str, member_id: &str, caller_id: &str) -> Result<Value, AppError> {
    let caller = organizer(db, org_id, caller_id).await?;
    let m = target(db, org_id, member_id).await?;
    if !m["reset_password_key"].is_string() || i(&m, "status") != CONFIRMED {
        return Err(bad("This member has not turned on family recovery"));
    }
    if i(&m, "type") < i(&caller, "type") || s(&m, "user_id").as_deref() == Some(caller_id) {
        return Err(AppError::Unauthorized("Not allowed".into()));
    }
    Ok(m)
}

/// GET /api/organizations/{org_id}/users/{member_id}/reset-password-details
#[worker::send]
pub async fn recovery_details(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let m = recoverable(&db, &org_id, &member_id, &claims.sub).await?;
    let u: Value = db.prepare("SELECT u.kdf_type, u.kdf_iterations, u.kdf_memory, u.kdf_parallelism, u.email, o.private_key FROM users u, organizations o WHERE u.id = ?1 AND o.id = ?2")
        .bind(&[m["user_id"].as_str().unwrap_or_default().into(), org_id.into()])?.first(None).await?.ok_or(AppError::Internal)?;
    Ok(Json(json!({"object": "organizationUserResetPasswordDetails", "organizationUserId": member_id, "email": u["email"],
        "kdf": u["kdf_type"], "kdfIterations": u["kdf_iterations"], "kdfMemory": u["kdf_memory"], "kdfParallelism": u["kdf_parallelism"],
        "resetPasswordKey": m["reset_password_key"], "encryptedPrivateKey": u["private_key"]})))
}

/// PUT /api/organizations/{org_id}/users/{member_id}/reset-password {newMasterPasswordHash, key}
/// The organizer sets a temporary account password for the member (the member's user key, re-wrapped with it).
/// All of the member's sessions end; the app asks them to choose their own password on next unlock.
#[worker::send]
pub async fn recover(claims: Claims, State(env): State<Arc<Env>>, Path((org_id, member_id)): Path<(String, String)>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let m = recoverable(&db, &org_id, &member_id, &claims.sub).await?;
    let hash = s(&p, "newMasterPasswordHash").ok_or_else(|| bad("newMasterPasswordHash"))?;
    let key = s(&p, "key").ok_or_else(|| bad("key"))?;
    let salt = crate::crypto::generate_salt()?;
    let iters = crate::handlers::server_password_iterations(&env);
    let stored = crate::crypto::hash_password_for_storage(&hash, &salt, iters).await?;
    let uid = s(&m, "user_id").unwrap_or_default();
    d1_query!(&db, "UPDATE users SET master_password_hash = ?1, password_salt = ?2, password_iterations = ?3, key = ?4, security_stamp = ?5, updated_at = ?6 WHERE id = ?7",
        stored, salt, iters as i64, key, Uuid::new_v4().to_string(), db::now_string(), uid)
        .map_err(|_| AppError::Database)?.run().await?;
    d1_query!(&db, "DELETE FROM devices WHERE user_id = ?1", uid).map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

/// POST /api/azet/travel-mode {enabled, masterPasswordHash} — while on, only travel-safe items and vaults sync.
#[worker::send]
pub async fn travel_mode(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    crate::handlers::accounts::checked_user(&db, &claims.sub, &s(&p, "masterPasswordHash").unwrap_or_default()).await?;
    let now = db::now_string();
    d1_query!(&db, "UPDATE users SET travel_mode = ?1, updated_at = ?2 WHERE id = ?3", b(&p, "enabled") as i64, now, claims.sub)
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({"travelMode": b(&p, "enabled")})))
}

/// PUT /api/ciphers/{id}/travel-safe {travelSafe} — personal items (shared vaults are marked as a whole).
#[worker::send]
pub async fn travel_safe(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let now = db::now_string();
    d1_query!(&db, "UPDATE ciphers SET travel_safe = ?1, updated_at = ?2 WHERE id = ?3 AND user_id = ?4", b(&p, "travelSafe") as i64, now, id, claims.sub)
        .map_err(|_| AppError::Database)?.run().await?;
    db::touch_user_updated_at(&db, &claims.sub, &now).await?;
    Ok(Json(json!({})))
}
