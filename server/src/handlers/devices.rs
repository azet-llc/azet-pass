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
