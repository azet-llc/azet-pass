//! Emergency access on Bitwarden's wire shape: a person (grantor) names a trusted contact (grantee) who may ask for
//! their vault; after a wait the grantor did not stop, the grantee can view it or take the account over.
//! Keys arrive wrapped by the clients: at confirm the grantor's device wraps its user key with the grantee's public
//! key (`keyEncrypted`); the server stores it and hands it only to the grantee once access is approved.
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
use crate::handlers::ciphers::RawJson;

pub(crate) const VIEW: i64 = 0;
pub(crate) const TAKEOVER: i64 = 1;
const INVITED: i64 = 0;
const ACCEPTED: i64 = 1;
const CONFIRMED: i64 = 2;
const RECOVERY_INITIATED: i64 = 3;
const RECOVERY_APPROVED: i64 = 4;
const MAX_WAIT_DAYS: i64 = 90;

fn bad(msg: &str) -> AppError {
    AppError::BadRequest(msg.to_string())
}

fn s(v: &Value, k: &str) -> Option<String> {
    v.get(k).and_then(|x| x.as_str()).map(|x| x.to_string())
}

fn i(v: &Value, k: &str) -> i64 {
    v.get(k).and_then(|x| x.as_i64()).unwrap_or(-1)
}

/// Checked `type` and `waitTimeDays` of an invite or an edit.
pub(crate) fn terms(p: &Value) -> Result<(i64, i64), AppError> {
    let kind = p.get("type").and_then(|x| x.as_i64()).ok_or_else(|| bad("type"))?;
    let days = p.get("waitTimeDays").and_then(|x| x.as_i64()).ok_or_else(|| bad("waitTimeDays"))?;
    if kind != VIEW && kind != TAKEOVER {
        return Err(bad("type is 0 (view) or 1 (takeover)"));
    }
    if !(1..=MAX_WAIT_DAYS).contains(&days) {
        return Err(bad("waitTimeDays is 1 to 90"));
    }
    Ok((kind, days))
}

/// A request the grantor neither approved nor rejected within the wait is approved (Bitwarden runs this as a job).
async fn settle(db: &db::Db) -> Result<(), AppError> {
    d1_query!(db, "UPDATE emergency_access SET status = ?1, updated_at = ?2
        WHERE status = ?3 AND datetime(recovery_initiated_at, '+' || wait_time_days || ' days') <= datetime('now')",
        RECOVERY_APPROVED, db::now_string(), RECOVERY_INITIATED)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(())
}

async fn row(db: &db::Db, id: &str) -> Result<Value, AppError> {
    settle(db).await?;
    db.prepare("SELECT * FROM emergency_access WHERE id = ?1")
        .bind(&[id.into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::NotFound("Emergency access not valid.".into()))
}

/// The grant, when the caller is its grantor (404 otherwise, so ids cannot be probed).
async fn as_grantor(db: &db::Db, id: &str, user: &str) -> Result<Value, AppError> {
    let r = row(db, id).await?;
    if s(&r, "grantor_id").as_deref() != Some(user) {
        return Err(AppError::NotFound("Emergency access not valid.".into()));
    }
    Ok(r)
}

async fn as_grantee(db: &db::Db, id: &str, user: &str) -> Result<Value, AppError> {
    let r = row(db, id).await?;
    if s(&r, "grantee_id").as_deref() != Some(user) {
        return Err(AppError::NotFound("Emergency access not valid.".into()));
    }
    Ok(r)
}

async fn set_status(db: &db::Db, id: &str, status: i64, initiated: Option<String>) -> Result<(), AppError> {
    d1_query!(db, "UPDATE emergency_access SET status = ?1, recovery_initiated_at = ?2, updated_at = ?3 WHERE id = ?4",
        status, initiated, db::now_string(), id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(())
}

/// The moment a pending request turns into access by itself (null when nothing is pending).
fn opens_at(r: &Value) -> Value {
    match (s(r, "recovery_initiated_at"), i(r, "status")) {
        (Some(at), RECOVERY_INITIATED) => chrono::DateTime::parse_from_rfc3339(&at)
            .map(|t| json!((t + chrono::Duration::days(i(r, "wait_time_days"))).to_rfc3339()))
            .unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

fn details(r: &Value, object: &str, other: &str) -> Value {
    let mut d = json!({
        "object": object,
        "id": r["id"], "status": r["status"], "type": r["type"], "waitTimeDays": r["wait_time_days"],
        "creationDate": r["created_at"], "lastNotificationDate": r["recovery_initiated_at"],
        "recoveryInitiatedDate": r["recovery_initiated_at"], "azetOpensAt": opens_at(r),
        "name": r["name"], "email": r["email"], "avatarColor": null,
    });
    d[format!("{other}Id")] = r[format!("{other}_id")].clone();
    d
}

const LIST_TRUSTED: &str = "SELECT ea.*, u.name AS name, COALESCE(u.email, ea.grantee_email) AS email
    FROM emergency_access ea LEFT JOIN users u ON u.id = ea.grantee_id WHERE ea.grantor_id = ?1 ORDER BY ea.created_at";
const LIST_GRANTED: &str = "SELECT ea.*, u.name AS name, u.email AS email
    FROM emergency_access ea JOIN users u ON u.id = ea.grantor_id
    WHERE ea.grantee_id = ?1 OR (ea.grantee_id IS NULL AND ea.grantee_email = ?2) ORDER BY ea.created_at";

/// GET /api/emergency-access/trusted — the caller's trusted contacts (the caller is the grantor).
#[worker::send]
pub async fn get_trusted_contacts(claims: Claims, State(env): State<Arc<Env>>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    settle(&db).await?;
    let rows: Vec<Value> = db.prepare(LIST_TRUSTED).bind(&[claims.sub.into()])?.all().await?.results()?;
    let data: Vec<Value> = rows.iter().map(|r| details(r, "emergencyAccessGranteeDetails", "grantee")).collect();
    Ok(Json(json!({"data": data, "object": "list", "continuationToken": null})))
}

/// GET /api/emergency-access/granted — people who named the caller (invites to the caller's address included).
#[worker::send]
pub async fn get_granted_access(claims: Claims, State(env): State<Arc<Env>>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    settle(&db).await?;
    let rows: Vec<Value> = db
        .prepare(LIST_GRANTED)
        .bind(&[claims.sub.into(), claims.email.to_lowercase().into()])?
        .all()
        .await?
        .results()?;
    let data: Vec<Value> = rows.iter().map(|r| details(r, "emergencyAccessGrantorDetails", "grantor")).collect();
    Ok(Json(json!({"data": data, "object": "list", "continuationToken": null})))
}

/// GET /api/emergency-access/{id}
#[worker::send]
pub async fn get_one(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = as_grantor(&db, &id, &claims.sub).await?;
    let u: Option<Value> = db.prepare("SELECT name, email FROM users WHERE id = ?1")
        .bind(&[s(&r, "grantee_id").unwrap_or_default().into()])?.first(None).await?;
    let mut r = r;
    r["name"] = u.as_ref().map(|u| u["name"].clone()).unwrap_or(Value::Null);
    r["email"] = u.map(|u| u["email"].clone()).unwrap_or_else(|| r["grantee_email"].clone());
    Ok(Json(details(&r, "emergencyAccessGranteeDetails", "grantee")))
}

/// POST /api/emergency-access/invite {email, type, waitTimeDays}
#[worker::send]
pub async fn invite(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let (kind, days) = terms(&p)?;
    let email = s(&p, "email").map(|e| e.trim().to_lowercase()).filter(|e| e.contains('@')).ok_or_else(|| bad("email"))?;
    if email == claims.email.to_lowercase() {
        return Err(bad("You cannot be your own emergency contact."));
    }
    let taken: Option<Value> = db
        .prepare("SELECT ea.id FROM emergency_access ea LEFT JOIN users u ON u.id = ea.grantee_id
            WHERE ea.grantor_id = ?1 AND (ea.grantee_email = ?2 OR lower(u.email) = ?2)")
        .bind(&[claims.sub.clone().into(), email.clone().into()])?
        .first(None)
        .await?;
    if taken.is_some() {
        return Err(bad("This person is already your emergency contact."));
    }
    let id = Uuid::new_v4().to_string();
    let now = db::now_string();
    d1_query!(&db, "INSERT INTO emergency_access (id, grantor_id, grantee_id, grantee_email, type, status, wait_time_days, created_at, updated_at)
        VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, ?7)", id, claims.sub, email, kind, INVITED, days, now)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(Json(json!({"id": id})))
}

/// POST /api/emergency-access/{id}/reinvite — there is no invite mail; the invite waits in the contact's list.
#[worker::send]
pub async fn reinvite(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = as_grantor(&db, &id, &claims.sub).await?;
    if i(&r, "status") != INVITED {
        return Err(bad("The contact already accepted."));
    }
    Ok(Json(json!({})))
}

/// POST /api/emergency-access/{id}/accept — by the invited person, signed in with the invited address.
#[worker::send]
pub async fn accept(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = row(&db, &id).await?;
    if i(&r, "status") != INVITED || s(&r, "grantee_email").as_deref() != Some(claims.email.to_lowercase().as_str()) {
        return Err(AppError::NotFound("Emergency access not valid.".into()));
    }
    d1_query!(&db, "UPDATE emergency_access SET grantee_id = ?1, grantee_email = NULL, status = ?2, updated_at = ?3 WHERE id = ?4",
        claims.sub, ACCEPTED, db::now_string(), id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(Json(json!({})))
}

/// POST /api/emergency-access/{id}/confirm {key} — the grantor's user key, wrapped with the grantee's public key.
#[worker::send]
pub async fn confirm(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = as_grantor(&db, &id, &claims.sub).await?;
    let key = s(&p, "key").filter(|k| k.starts_with("4.")).ok_or_else(|| bad("key (RSA-wrapped user key)"))?;
    if i(&r, "status") != ACCEPTED {
        return Err(bad("The contact has not accepted yet."));
    }
    d1_query!(&db, "UPDATE emergency_access SET key_encrypted = ?1, status = ?2, updated_at = ?3 WHERE id = ?4",
        key, CONFIRMED, db::now_string(), id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(Json(json!({})))
}

/// PUT|POST /api/emergency-access/{id} {type, waitTimeDays}
#[worker::send]
pub async fn update(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    as_grantor(&db, &id, &claims.sub).await?;
    let (kind, days) = terms(&p)?;
    d1_query!(&db, "UPDATE emergency_access SET type = ?1, wait_time_days = ?2, updated_at = ?3 WHERE id = ?4",
        kind, days, db::now_string(), id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(Json(json!({})))
}

/// DELETE /api/emergency-access/{id} (and POST …/delete) — by either side.
#[worker::send]
pub async fn delete(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = row(&db, &id).await?;
    if s(&r, "grantor_id").as_deref() != Some(claims.sub.as_str()) && s(&r, "grantee_id").as_deref() != Some(claims.sub.as_str()) {
        return Err(AppError::NotFound("Emergency access not valid.".into()));
    }
    d1_query!(&db, "DELETE FROM emergency_access WHERE id = ?1", id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;
    Ok(Json(json!({})))
}

/// POST /api/emergency-access/{id}/initiate — the grantee asks; the wait starts.
#[worker::send]
pub async fn initiate(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = as_grantee(&db, &id, &claims.sub).await?;
    if i(&r, "status") != CONFIRMED {
        return Err(bad("Emergency access is not confirmed, or a request is already open."));
    }
    set_status(&db, &id, RECOVERY_INITIATED, Some(db::now_string())).await?;
    Ok(Json(json!({})))
}

/// POST /api/emergency-access/{id}/approve — the grantor lets the request through before the wait ends.
#[worker::send]
pub async fn approve(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = as_grantor(&db, &id, &claims.sub).await?;
    if i(&r, "status") != RECOVERY_INITIATED {
        return Err(bad("There is no open request."));
    }
    set_status(&db, &id, RECOVERY_APPROVED, s(&r, "recovery_initiated_at")).await?;
    Ok(Json(json!({})))
}

/// POST /api/emergency-access/{id}/reject — the grantor stops a request, or ends access already given.
#[worker::send]
pub async fn reject(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = as_grantor(&db, &id, &claims.sub).await?;
    if !matches!(i(&r, "status"), RECOVERY_INITIATED | RECOVERY_APPROVED) {
        return Err(bad("There is no open request."));
    }
    set_status(&db, &id, CONFIRMED, None).await?;
    Ok(Json(json!({})))
}

async fn approved(db: &db::Db, id: &str, user: &str, kind: i64) -> Result<Value, AppError> {
    let r = as_grantee(db, id, user).await?;
    if i(&r, "status") != RECOVERY_APPROVED || i(&r, "type") != kind || !r["key_encrypted"].is_string() {
        return Err(bad("Emergency access is not approved."));
    }
    Ok(r)
}

/// POST /api/emergency-access/{id}/view — the grantor's own items (not shared vaults) and the wrapped key.
#[worker::send]
pub async fn view(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<RawJson, AppError> {
    let db = db::get_db(&env)?;
    let r = approved(&db, &id, &claims.sub, VIEW).await?;
    let mut out = String::from("{\"ciphers\":");
    crate::handlers::ciphers::append_cipher_json_array_raw(
        &mut out,
        &db,
        crate::handlers::attachments::attachments_enabled(&env),
        "WHERE c.user_id = ?1 AND c.organization_id IS NULL AND c.deleted_at IS NULL",
        &[s(&r, "grantor_id").unwrap_or_default().into()],
        "ORDER BY c.updated_at DESC",
        crate::handlers::ciphers_default_row_query(&env),
    )
    .await?;
    out.push_str(&format!(",\"keyEncrypted\":{},\"object\":\"emergencyAccessView\"}}", r["key_encrypted"]));
    Ok(RawJson(out))
}

/// POST /api/emergency-access/{id}/takeover — what the grantee's device needs to set a new password.
#[worker::send]
pub async fn takeover(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = approved(&db, &id, &claims.sub, TAKEOVER).await?;
    let u: Value = db.prepare("SELECT kdf_type, kdf_iterations, kdf_memory, kdf_parallelism, email FROM users WHERE id = ?1")
        .bind(&[s(&r, "grantor_id").unwrap_or_default().into()])?.first(None).await?.ok_or(AppError::Internal)?;
    Ok(Json(json!({"object": "emergencyAccessTakeover", "keyEncrypted": r["key_encrypted"], "email": u["email"],
        "kdf": u["kdf_type"], "kdfIterations": u["kdf_iterations"], "kdfMemory": u["kdf_memory"], "kdfParallelism": u["kdf_parallelism"]})))
}

/// POST /api/emergency-access/{id}/password {newMasterPasswordHash, key} — the grantee sets the grantor's account
/// password (the grantor's user key, wrapped with it). Every session of the grantor ends.
#[worker::send]
pub async fn password(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>, Json(p): Json<Value>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let r = approved(&db, &id, &claims.sub, TAKEOVER).await?;
    let hash = s(&p, "newMasterPasswordHash").ok_or_else(|| bad("newMasterPasswordHash"))?;
    let key = s(&p, "key").ok_or_else(|| bad("key"))?;
    let salt = crate::crypto::generate_salt()?;
    let iters = crate::handlers::server_password_iterations(&env);
    let stored = crate::crypto::hash_password_for_storage(&hash, &salt, iters).await?;
    let uid = s(&r, "grantor_id").unwrap_or_default();
    d1_query!(&db, "UPDATE users SET master_password_hash = ?1, password_salt = ?2, password_iterations = ?3, key = ?4, security_stamp = ?5, updated_at = ?6 WHERE id = ?7",
        stored, salt, iters as i64, key, Uuid::new_v4().to_string(), db::now_string(), uid)
        .map_err(|_| AppError::Database)?.run().await?;
    d1_query!(&db, "DELETE FROM devices WHERE user_id = ?1", uid).map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}

/// GET /api/emergency-access/{id}/policies — no organization policies apply to a takeover here.
#[worker::send]
pub async fn policies(claims: Claims, State(env): State<Arc<Env>>, Path(id): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    approved(&db, &id, &claims.sub, TAKEOVER).await?;
    Ok(Json(json!({"data": [], "object": "list", "continuationToken": null})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terms_are_checked() {
        assert_eq!(terms(&json!({"type": 1, "waitTimeDays": 7})).unwrap(), (1, 7));
        assert!(terms(&json!({"type": 2, "waitTimeDays": 7})).is_err());
        assert!(terms(&json!({"type": 0, "waitTimeDays": 0})).is_err());
        assert!(terms(&json!({"type": 0, "waitTimeDays": 91})).is_err());
        assert!(terms(&json!({"type": 0})).is_err());
    }

    #[test]
    fn a_pending_request_says_when_it_opens() {
        let r = json!({"status": RECOVERY_INITIATED, "recovery_initiated_at": "2026-11-01T00:00:00.000Z", "wait_time_days": 7});
        assert_eq!(opens_at(&r), json!("2026-11-08T00:00:00+00:00"));
        assert_eq!(opens_at(&json!({"status": CONFIRMED, "recovery_initiated_at": null, "wait_time_days": 7})), Value::Null);
    }
}
