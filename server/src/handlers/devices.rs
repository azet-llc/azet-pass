use axum::{
    extract::{Path, State},
    http::HeaderMap,
    Json,
};
use base64::{engine::general_purpose, Engine as _};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use worker::Env;

use crate::{
    auth::Claims, db, error::AppError, models::auth_request::AuthRequest, models::device::Device,
};

fn required_header(headers: &HeaderMap, name: &str) -> Result<String, AppError> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| AppError::BadRequest(format!("Missing {name} header")))
}

fn decode_base64url_email(encoded: &str) -> Result<String, AppError> {
    let decoded = general_purpose::URL_SAFE_NO_PAD
        .decode(encoded)
        .or_else(|_| general_purpose::URL_SAFE.decode(encoded))
        .map_err(|_| AppError::BadRequest("Invalid X-Request-Email header".to_string()))?;
    String::from_utf8(decoded)
        .map_err(|_| AppError::BadRequest("Invalid X-Request-Email header".to_string()))
}

async fn current_device(
    db: &crate::db::Db,
    claims: &Claims,
    path_device_id: &str,
) -> Result<Device, AppError> {
    if path_device_id != claims.device.as_str() {
        return Err(AppError::Unauthorized(
            "Can only manage the current authenticated device".to_string(),
        ));
    }

    Device::find_by_identifier_and_user(db, &claims.device, &claims.sub)
        .await?
        .ok_or_else(|| AppError::Unauthorized("Invalid token".to_string()))
}

/// GET /devices
#[worker::send]
pub async fn get_devices(
    State(env): State<Arc<Env>>,
    claims: Claims,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let devices = Device::list_by_user(&db, &claims.sub).await?;
    let pending = AuthRequest::list_pending_by_user(&db, &claims.sub).await?;

    let data: Vec<Value> = devices
        .iter()
        .map(|device| {
            let pending_for_device = pending
                .iter()
                .find(|ar| ar.request_device_identifier == device.identifier);
            let mut json = device.to_json();
            json["devicePendingAuthRequest"] = pending_for_device
                .map(AuthRequest::to_pending_device_json)
                .unwrap_or(Value::Null);
            json
        })
        .collect();

    Ok(Json(json!({
        "data": data,
        "continuationToken": null,
        "object": "list"
    })))
}

/// GET /devices/knowndevice
#[worker::send]
pub async fn get_known_device(
    State(env): State<Arc<Env>>,
    headers: HeaderMap,
) -> Result<Json<bool>, AppError> {
    let encoded_email = required_header(&headers, "X-Request-Email")?;
    let identifier = required_header(&headers, "X-Device-Identifier")?;
    let email = decode_base64url_email(&encoded_email)?.to_lowercase();
    let db = db::get_db(&env)?;

    let user_id: Option<String> = db
        .prepare("SELECT id FROM users WHERE email = ?1")
        .bind(&[email.into()])?
        .first(Some("id"))
        .await
        .map_err(|_| AppError::Database)?;

    let is_known = if let Some(user_id) = user_id {
        Device::find_by_identifier_and_user(&db, &identifier, &user_id)
            .await?
            .is_some()
    } else {
        false
    };

    Ok(Json(is_known))
}

/// GET /devices/identifier/{device_id}
#[worker::send]
pub async fn get_device(
    State(env): State<Arc<Env>>,
    claims: Claims,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let device = Device::find_by_identifier_and_user(&db, &device_id, &claims.sub)
        .await?
        .ok_or_else(|| AppError::NotFound("Device not found".to_string()))?;

    Ok(Json(device.to_json()))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PushToken {
    push_token: String,
}

async fn upsert_device_token(
    env: Arc<Env>,
    claims: Claims,
    device_id: String,
    push_token: String,
) -> Result<Json<Value>, AppError> {
    let push_token = push_token.trim().to_string();
    if push_token.is_empty() {
        return Err(AppError::BadRequest("Missing pushToken".to_string()));
    }

    let db = db::get_db(&env)?;
    let mut device = current_device(&db, &claims, &device_id).await?;
    if device.push_token.as_deref() == Some(push_token.as_str()) {
        log::debug!(
            "Device {} for user {} is already registered and token is identical",
            device_id,
            claims.sub
        );
        return Ok(Json(json!({})));
    }

    device.set_push_token(&db, Some(&push_token)).await?;

    Ok(Json(json!({})))
}

/// POST /devices/identifier/{device_id}/token
#[worker::send]
pub async fn post_device_token(
    State(env): State<Arc<Env>>,
    claims: Claims,
    Path(device_id): Path<String>,
    Json(data): Json<PushToken>,
) -> Result<Json<Value>, AppError> {
    upsert_device_token(env, claims, device_id, data.push_token).await
}

/// PUT /devices/identifier/{device_id}/token
#[worker::send]
pub async fn put_device_token(
    State(env): State<Arc<Env>>,
    claims: Claims,
    Path(device_id): Path<String>,
    Json(data): Json<PushToken>,
) -> Result<Json<Value>, AppError> {
    upsert_device_token(env, claims, device_id, data.push_token).await
}

async fn clear_device_token(
    env: Arc<Env>,
    claims: Claims,
    device_id: String,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let mut device = current_device(&db, &claims, &device_id).await?;

    device.set_push_token(&db, None).await?;

    Ok(Json(json!({})))
}

/// PUT /devices/identifier/{device_id}/clear-token
#[worker::send]
pub async fn put_clear_device_token(
    State(env): State<Arc<Env>>,
    claims: Claims,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    clear_device_token(env, claims, device_id).await
}

/// POST /devices/identifier/{device_id}/clear-token
#[worker::send]
pub async fn post_clear_device_token(
    State(env): State<Arc<Env>>,
    claims: Claims,
    Path(device_id): Path<String>,
) -> Result<Json<Value>, AppError> {
    clear_device_token(env, claims, device_id).await
}

#[worker::send]
pub async fn deactivate(
    State(env): State<Arc<Env>>,
    claims: Claims,
    Path(id): Path<String>,
) -> Result<axum::http::StatusCode, AppError> {
    let db = db::get_db(&env)?;
    Device::find_by_identifier_and_user(&db, &id, &claims.sub)
        .await?
        .ok_or_else(|| AppError::NotFound("Device not found".into()))?;
    // The removed device hears LogOut now and wipes its local vault (it would lose access at its next refresh).
    crate::push::sign_out_device(&env, &claims.sub, &id, &db::now_string()).await;
    db.prepare("DELETE FROM devices WHERE identifier = ?1 AND user_id = ?2")
        .bind(&[id.into(), claims.sub.into()])?
        .run()
        .await
        .map_err(|_| AppError::Database)?;
    Ok(axum::http::StatusCode::OK)
}

// New-device approval (spass-186): off by default. When on, a password sign-in from a device the account has never
// used is refused until a device already signed in approves it; the new device then signs in again. Sign-in with a
// device (auth requests) is already approved by an existing device and is not held here.
const APPROVAL_WAIT_MINUTES: f64 = 60.0;

pub(crate) const APPROVAL_NEEDED: &str = "This device needs approval. Approve it on a device already signed in to AZET Pass (azet-desktop pass devices approve), then sign in again.";

/// Called after the password and two-step login checked out, for a device the account did not know before this
/// sign-in. Ok(()) lets the sign-in through; otherwise the device waits in device_approvals.
pub(crate) async fn approval_gate(db: &crate::db::Db, user_id: &str, identifier: &str, name: &str, kind: i32) -> Result<(), AppError> {
    let on: Option<Value> = db
        .prepare("SELECT 1 AS held FROM users u WHERE u.id = ?1 AND u.device_approval = 1
            AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = u.id AND d.identifier != ?2)")
        .bind(&[user_id.into(), identifier.into()])?
        .first(None)
        .await?;
    if on.is_none() {
        return Ok(()); // off, or no other device to approve from (the first device is never locked out)
    }
    let row: Option<Value> = db
        .prepare("SELECT approved_at FROM device_approvals WHERE user_id = ?1 AND identifier = ?2
            AND datetime(created_at, '+' || ?3 || ' minutes') > datetime('now')")
        .bind(&[user_id.into(), identifier.into(), APPROVAL_WAIT_MINUTES.into()])?
        .first(None)
        .await?;
    if row.as_ref().is_some_and(|r| r["approved_at"].is_string()) {
        crate::d1_query!(db, "DELETE FROM device_approvals WHERE user_id = ?1 AND identifier = ?2", user_id, identifier)
            .map_err(|_| AppError::Database)?.run().await?;
        return Ok(());
    }
    if row.is_none() {
        crate::d1_query!(db, "INSERT OR REPLACE INTO device_approvals (user_id, identifier, name, type, created_at, approved_at)
            VALUES (?1, ?2, ?3, ?4, ?5, NULL)", user_id, identifier, name, kind, db::now_string())
            .map_err(|_| AppError::Database)?.run().await?;
    }
    // the row get_or_create made during this sign-in goes, so the device stays unknown until it is approved
    crate::d1_query!(db, "DELETE FROM devices WHERE user_id = ?1 AND identifier = ?2", user_id, identifier)
        .map_err(|_| AppError::Database)?.run().await?;
    Err(AppError::BadRequest(APPROVAL_NEEDED.to_string()))
}

/// GET /api/azet/device-approval → {enabled, pending: [{identifier, name, type, creationDate}]}
#[worker::send]
pub async fn approval_status(claims: Claims, State(env): State<Arc<Env>>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user: Value = db
        .prepare("SELECT device_approval FROM users WHERE id = ?1")
        .bind(&[claims.sub.clone().into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::Unauthorized("user".into()))?;
    let pending: Vec<Value> = db
        .prepare("SELECT identifier, name, type, created_at AS creationDate FROM device_approvals
            WHERE user_id = ?1 AND approved_at IS NULL AND datetime(created_at, '+' || ?2 || ' minutes') > datetime('now')
            ORDER BY created_at")
        .bind(&[claims.sub.into(), APPROVAL_WAIT_MINUTES.into()])?
        .all()
        .await?
        .results()?;
    Ok(Json(json!({"enabled": user["device_approval"].as_i64() == Some(1), "pending": pending})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalSetting {
    enabled: bool,
    master_password_hash: String,
}

/// POST /api/azet/device-approval {enabled, masterPasswordHash}
#[worker::send]
pub async fn set_approval(claims: Claims, State(env): State<Arc<Env>>, Json(p): Json<ApprovalSetting>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    crate::handlers::accounts::checked_user(&db, &claims.sub, &p.master_password_hash).await?;
    crate::d1_query!(&db, "UPDATE users SET device_approval = ?1, updated_at = ?2 WHERE id = ?3", p.enabled as i64, db::now_string(), claims.sub)
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({"enabled": p.enabled})))
}

/// POST /api/azet/device-approval/{identifier}/approve — from a device already signed in.
#[worker::send]
pub async fn approve_device(claims: Claims, State(env): State<Arc<Env>>, Path(identifier): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let changed = crate::d1_query!(&db, "UPDATE device_approvals SET approved_at = ?1 WHERE user_id = ?2 AND identifier = ?3 AND approved_at IS NULL",
        db::now_string(), claims.sub, identifier)
        .map_err(|_| AppError::Database)?
        .run()
        .await?
        .meta()
        .map_err(|_| AppError::Database)?
        .and_then(|m| m.changes)
        .unwrap_or(0);
    if changed == 0 {
        return Err(AppError::NotFound("No device is waiting with that id.".into()));
    }
    Ok(Json(json!({})))
}

/// POST /api/azet/device-approval/{identifier}/deny
#[worker::send]
pub async fn deny_device(claims: Claims, State(env): State<Arc<Env>>, Path(identifier): Path<String>) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    crate::d1_query!(&db, "DELETE FROM device_approvals WHERE user_id = ?1 AND identifier = ?2", claims.sub, identifier)
        .map_err(|_| AppError::Database)?.run().await?;
    Ok(Json(json!({})))
}
