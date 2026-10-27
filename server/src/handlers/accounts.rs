use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use glob_match::glob_match;
use serde_json::{json, Value};
use std::sync::Arc;
use uuid::Uuid;
use worker::{D1PreparedStatement, Env};

use crate::d1_query;

use super::{
    enforce_ip_rate_limit, get_batch_size, server_password_iterations, two_factor_enabled,
};
use crate::{
    auth::Claims,
    crypto::{generate_salt, hash_password_for_storage},
    db,
    error::AppError,
    handlers::{attachments, sends},
    models::{
        cipher::CipherData,
        device::Device,
        sync::Profile,
        user::{
            AvatarData, ChangeKdfRequest, ChangePasswordRequest, MasterPasswordUnlockData,
            PasswordHintRequest, PasswordOrOtpData, PreloginKdfSettings, PreloginResponse,
            ProfileData, RegisterRequest, RotateKeyRequest, User,
        },
    },
    notifications::{self, UpdateType},
    push,
};

const KDF_TYPE_PBKDF2: i32 = 0;
const KDF_TYPE_ARGON2ID: i32 = 1;
const MIN_PBKDF2_ITERATIONS: i32 = 100_000;
const DEFAULT_PBKDF2_ITERATIONS: i32 = 600_000;

fn ensure_supported_kdf(
    kdf_type: i32,
    iterations: i32,
    memory: Option<i32>,
    parallelism: Option<i32>,
) -> Result<(), AppError> {
    match kdf_type {
        KDF_TYPE_PBKDF2 => {
            if iterations < MIN_PBKDF2_ITERATIONS {
                return Err(AppError::BadRequest(format!(
                    "PBKDF2 iterations must be at least {}",
                    MIN_PBKDF2_ITERATIONS
                )));
            }
        }
        KDF_TYPE_ARGON2ID => {
            if iterations < 1 {
                return Err(AppError::BadRequest(
                    "Argon2 KDF iterations must be at least 1".to_string(),
                ));
            }
            match memory {
                Some(m) if (15..=1024).contains(&m) => {}
                Some(_) => {
                    return Err(AppError::BadRequest(
                        "Argon2 memory must be between 15 MB and 1024 MB".to_string(),
                    ));
                }
                None => {
                    return Err(AppError::BadRequest(
                        "Argon2 memory parameter is required".to_string(),
                    ));
                }
            }
            match parallelism {
                Some(p) if (1..=16).contains(&p) => {}
                Some(_) => {
                    return Err(AppError::BadRequest(
                        "Argon2 parallelism must be between 1 and 16".to_string(),
                    ));
                }
                None => {
                    return Err(AppError::BadRequest(
                        "Argon2 parallelism parameter is required".to_string(),
                    ));
                }
            }
        }
        _ => {
            return Err(AppError::BadRequest(
                "Unsupported KDF type. Only PBKDF2 (0) and Argon2id (1) are supported".to_string(),
            ));
        }
    }

    Ok(())
}

fn validate_rotation_metadata(
    user: &User,
    unlock_data: &MasterPasswordUnlockData,
    account_public_key: &str,
) -> Result<(), AppError> {
    let kdf_matches = user.kdf_type == unlock_data.kdf_type
        && user.kdf_iterations == unlock_data.kdf_iterations
        && user.kdf_memory == unlock_data.kdf_memory
        && user.kdf_parallelism == unlock_data.kdf_parallelism;

    if user.email != unlock_data.email || !kdf_matches {
        log::error!(
            "KDF/email mismatch in rotation request: email_equal={}, kdf_equal={}",
            user.email == unlock_data.email,
            kdf_matches
        );
        return Err(AppError::BadRequest(
            "Changing the kdf variant or email is not supported during key rotation".to_string(),
        ));
    }

    if user.public_key != account_public_key {
        log::error!("Public key mismatch in rotation request: stored != provided");
        return Err(AppError::BadRequest(
            "Changing the asymmetric keypair is not supported during key rotation".to_string(),
        ));
    }

    Ok(())
}

#[worker::send]
pub async fn prelogin(
    State(env): State<Arc<Env>>,
    headers: HeaderMap,
    Json(payload): Json<serde_json::Value>,
) -> Result<Json<PreloginResponse>, AppError> {
    let email = payload["email"]
        .as_str()
        .ok_or_else(|| AppError::BadRequest("Missing email".to_string()))?;

    enforce_ip_rate_limit(
        &env,
        &headers,
        "LOGIN_RATE_LIMITER",
        "prelogin",
        "Too many requests. Please try again later.",
    )
    .await?;

    let db = db::get_db(&env)?;

    let stmt = db.prepare(
        "SELECT kdf_type, kdf_iterations, kdf_memory, kdf_parallelism FROM users WHERE email = ?1",
    );
    let query = stmt.bind(&[email.into()])?;
    let row: Option<Value> = query.first(None).await.map_err(|_| AppError::Database)?;

    let (kdf_type, kdf_iterations, kdf_memory, kdf_parallelism) = if let Some(row) = row {
        let kdf_type = row
            .get("kdf_type")
            .and_then(|value| value.as_i64())
            .map(|value| value as i32);
        let kdf_iterations = row
            .get("kdf_iterations")
            .and_then(|value| value.as_i64())
            .map(|value| value as i32);
        let kdf_memory = row
            .get("kdf_memory")
            .and_then(|value| value.as_i64())
            .map(|value| value as i32);
        let kdf_parallelism = row
            .get("kdf_parallelism")
            .and_then(|value| value.as_i64())
            .map(|value| value as i32);
        (kdf_type, kdf_iterations, kdf_memory, kdf_parallelism)
    } else {
        (None, None, None, None)
    };

    Ok(Json(PreloginResponse {
        kdf: kdf_type.unwrap_or(KDF_TYPE_PBKDF2),
        kdf_iterations: kdf_iterations.unwrap_or(DEFAULT_PBKDF2_ITERATIONS),
        kdf_memory,
        kdf_parallelism,
        kdf_settings: PreloginKdfSettings {
            iterations: kdf_iterations.unwrap_or(DEFAULT_PBKDF2_ITERATIONS),
            kdf_type: kdf_type.unwrap_or(KDF_TYPE_PBKDF2),
            memory: kdf_memory,
            parallelism: kdf_parallelism,
        },
        salt: None,
    }))
}

#[worker::send]
pub async fn register(
    State(env): State<Arc<Env>>,
    headers: HeaderMap,
    Json(payload): Json<RegisterRequest>,
) -> Result<Json<Value>, AppError> {
    enforce_ip_rate_limit(
        &env,
        &headers,
        "LOGIN_RATE_LIMITER",
        "register",
        "Too many requests. Please try again later.",
    )
    .await?;

    if !payload.has_valid_compat_format() {
        return Err(AppError::api_json(
            StatusCode::UNPROCESSABLE_ENTITY,
            json!({ "error": "Unexpected RegisterData format" }),
        ));
    }

    let allowed_emails = env
        .secret("ALLOWED_EMAILS")
        .map_err(|_| AppError::Internal)?;
    let allowed_emails = allowed_emails
        .as_ref()
        .as_string()
        .ok_or_else(|| AppError::Internal)?;
    if !allowed_emails
        .split(',')
        .any(|pattern| glob_match(pattern.trim(), &payload.email))
    {
        return Err(AppError::Unauthorized("Not allowed to signup".to_string()));
    }

    let kdf = payload.kdf();
    let kdf_type = kdf.kdf;
    let kdf_iterations = kdf.kdf_iterations;
    let kdf_memory = kdf.kdf_memory;
    let kdf_parallelism = kdf.kdf_parallelism;
    let master_password_hash = payload.master_password_hash().to_owned();
    let user_symmetric_key = payload.user_symmetric_key().to_owned();

    ensure_supported_kdf(kdf_type, kdf_iterations, kdf_memory, kdf_parallelism)?;

    // Generate salt and hash the password with server-side PBKDF2
    let password_salt = generate_salt()?;
    let password_iterations = server_password_iterations(&env) as i32;
    let hashed_password = hash_password_for_storage(
        &master_password_hash,
        &password_salt,
        password_iterations as u32,
    )
    .await?;

    let db = db::get_db(&env)?;
    let now = db::now_string();

    // Only store kdf_memory and kdf_parallelism for Argon2id, clear for PBKDF2
    let (kdf_memory, kdf_parallelism) = if kdf_type == KDF_TYPE_ARGON2ID {
        (kdf_memory, kdf_parallelism)
    } else {
        (None, None)
    };

    let user = User {
        id: Uuid::new_v4().to_string(),
        name: payload.name,
        avatar_color: None,
        email: payload.email.to_lowercase(),
        email_verified: false,
        master_password_hash: hashed_password,
        master_password_hint: payload.master_password_hint,
        password_salt: Some(password_salt),
        password_iterations,
        key: user_symmetric_key,
        private_key: payload.user_asymmetric_keys.encrypted_private_key,
        public_key: payload.user_asymmetric_keys.public_key,
        kdf_type,
        kdf_iterations,
        kdf_memory,
        kdf_parallelism,
        security_stamp: Uuid::new_v4().to_string(),
        equivalent_domains: "[]".to_string(),
        excluded_globals: "[]".to_string(),
        totp_recover: None,
        created_at: now.clone(),
        updated_at: now,
    };

    d1_query!(
        &db,
        "INSERT INTO users (id, name, email, master_password_hash, master_password_hint, password_salt, password_iterations, key, private_key, public_key, kdf_type, kdf_iterations, kdf_memory, kdf_parallelism, security_stamp, equivalent_domains, excluded_globals, totp_recover, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)",
         user.id,
         user.name,
         user.email,
         user.master_password_hash,
         user.master_password_hint,
         user.password_salt,
         user.password_iterations,
         user.key,
         user.private_key,
         user.public_key,
         user.kdf_type,
         user.kdf_iterations,
         user.kdf_memory,
         user.kdf_parallelism,
         user.security_stamp,
         user.equivalent_domains,
         user.excluded_globals,
         user.totp_recover,
         user.created_at,
         user.updated_at
    ).map_err(|_|{
        AppError::Database
    })?
    .run()
    .await
    .map_err(|_|{
        AppError::Database
    })?;

    Ok(Json(json!({})))
}

#[worker::send]
pub async fn password_hint(
    State(env): State<Arc<Env>>,
    headers: HeaderMap,
    Json(payload): Json<PasswordHintRequest>,
) -> Result<axum::response::Response, AppError> {
    enforce_ip_rate_limit(
        &env,
        &headers,
        "LOGIN_RATE_LIMITER",
        "password-hint",
        "Too many requests. Please try again later.",
    )
    .await?;

    let db = db::get_db(&env)?;
    let email = payload.email.trim().to_lowercase();
    let found: Option<Value> = db
        .prepare("SELECT master_password_hint FROM users WHERE email = ?1")
        .bind(&[email.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?;
    if let Some(row) = found {
        let hint = row["master_password_hint"].as_str().unwrap_or("").trim();
        let message = if hint.is_empty() {
            "No master password hint has been set.\n\n마스터 비밀번호 힌트가 설정되지 않았습니다."
                .to_string()
        } else {
            format!("Your master password hint: {hint}\n\n마스터 비밀번호 힌트: {hint}")
        };
        return mail_response(&email, "AZET Pass password hint", &message);
    }
    Ok(axum::http::StatusCode::OK.into_response())
}

#[worker::send]
pub async fn revision_date(
    claims: Claims,
    State(env): State<Arc<Env>>,
) -> Result<Json<i64>, AppError> {
    let db = db::get_db(&env)?;

    // get the user's updated_at timestamp
    let updated_at: Option<String> = db
        .prepare("SELECT updated_at FROM users WHERE id = ?1")
        .bind(&[claims.sub.into()])?
        .first(Some("updated_at"))
        .await
        .map_err(|_| AppError::Database)?;

    // convert the timestamp to a millisecond-level Unix timestamp
    let revision_date = updated_at
        .and_then(|ts| chrono::DateTime::parse_from_rfc3339(&ts).ok())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(|| chrono::Utc::now().timestamp_millis());

    Ok(Json(revision_date))
}

/// GET /api/tasks
///
/// Vaultwarden returns an empty list here; some official clients call this endpoint.
/// We don't implement task workflows, so always return an empty list.
#[worker::send]
pub async fn get_tasks() -> Result<Json<Value>, AppError> {
    Ok(Json(json!({
        "data": [],
        "object": "list"
    })))
}

#[worker::send]
pub async fn get_profile(
    claims: Claims,
    State(env): State<Arc<Env>>,
) -> Result<Json<Profile>, AppError> {
    let db = db::get_db(&env)?;
    let user_id = claims.sub;

    let user: User = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;

    let two_factor_enabled = two_factor_enabled(&db, &user_id).await?;
    let profile = {
        let premium = crate::handlers::azet::premium_for(&env, &user.id).await;
        Profile::from_user(user, two_factor_enabled, premium)?
    };

    Ok(Json(profile))
}

#[worker::send]
pub async fn post_profile(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<ProfileData>,
) -> Result<Json<Profile>, AppError> {
    if payload.name.len() > 50 {
        return Err(AppError::BadRequest(
            "The field Name must be a string with a maximum length of 50.".to_string(),
        ));
    }

    let db = db::get_db(&env)?;
    let user_id = &claims.sub;

    let user_value: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;

    let mut user: User = serde_json::from_value(user_value).map_err(|_| AppError::Internal)?;
    let now = db::now_string();

    user.name = Some(payload.name);
    user.updated_at = now.clone();

    d1_query!(
        &db,
        "UPDATE users SET name = ?1, updated_at = ?2 WHERE id = ?3",
        user.name,
        now,
        user_id
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await
    .map_err(|_| AppError::Database)?;

    let two_factor_enabled = two_factor_enabled(&db, user_id).await?;
    let profile = {
        let premium = crate::handlers::azet::premium_for(&env, &user.id).await;
        Profile::from_user(user, two_factor_enabled, premium)?
    };

    notifications::publish_user_update(
        (*env).clone(),
        claims.sub,
        UpdateType::SyncSettings,
        now,
        Some(claims.device),
    );

    Ok(Json(profile))
}

#[worker::send]
pub async fn put_profile(
    claims: Claims,
    state: State<Arc<Env>>,
    json: Json<ProfileData>,
) -> Result<Json<Profile>, AppError> {
    post_profile(claims, state, json).await
}

#[worker::send]
pub async fn put_avatar(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<AvatarData>,
) -> Result<Json<Profile>, AppError> {
    if let Some(color) = &payload.avatar_color {
        if color.len() != 7 {
            return Err(AppError::BadRequest(
                "The field AvatarColor must be a HTML/Hex color code with a length of 7 characters"
                    .to_string(),
            ));
        }
    }

    let db = db::get_db(&env)?;
    let user_id = &claims.sub;

    let user_value: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;

    let mut user: User = serde_json::from_value(user_value).map_err(|_| AppError::Internal)?;
    let now = db::now_string();

    user.avatar_color = payload.avatar_color;
    user.updated_at = now.clone();

    d1_query!(
        &db,
        "UPDATE users SET avatar_color = ?1, updated_at = ?2 WHERE id = ?3",
        user.avatar_color,
        now,
        user_id
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await
    .map_err(|_| AppError::Database)?;

    let two_factor_enabled = two_factor_enabled(&db, user_id).await?;
    let profile = {
        let premium = crate::handlers::azet::premium_for(&env, &user.id).await;
        Profile::from_user(user, two_factor_enabled, premium)?
    };

    notifications::publish_user_update(
        (*env).clone(),
        claims.sub,
        UpdateType::SyncSettings,
        now,
        Some(claims.device),
    );

    Ok(Json(profile))
}

#[worker::send]
pub async fn delete_account(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<PasswordOrOtpData>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user_id = &claims.sub;

    // Get the user from the database
    let user: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;
    let user: User = serde_json::from_value(user).map_err(|_| AppError::Internal)?;

    // Verify the master password hash
    let provided_hash = payload
        .master_password_hash
        .ok_or_else(|| AppError::BadRequest("Missing master password hash".to_string()))?;

    let verification = user.verify_master_password(&provided_hash).await?;

    if !verification.is_valid() {
        return Err(AppError::Unauthorized("Invalid password".to_string()));
    }

    push::unregister_push_devices_by_user(&env, user_id).await;

    if attachments::attachments_enabled(env.as_ref()) {
        let keys = attachments::list_attachment_keys_for_user(&db, user_id).await?;
        attachments::delete_storage_objects(env.as_ref(), &keys).await?;
    }

    // Delete all user's sends and associated storage objects
    sends::delete_user_sends(&db, env.as_ref(), user_id).await?;

    // Delete all user's ciphers
    d1_query!(&db, "DELETE FROM ciphers WHERE user_id = ?1", user_id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;

    // Delete all user's folders
    d1_query!(&db, "DELETE FROM folders WHERE user_id = ?1", user_id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;

    // Delete the user
    d1_query!(&db, "DELETE FROM users WHERE id = ?1", user_id)
        .map_err(|_| AppError::Database)?
        .run()
        .await?;

    crate::handlers::azet::release_seat(&env, user_id).await; // the account's licence seat goes back to the key
    Ok(Json(json!({})))
}

/// POST /accounts/password - Change master password
#[worker::send]
pub async fn post_password(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<ChangePasswordRequest>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user_id = &claims.sub;

    // Get the user from the database
    let user: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;
    let user: User = serde_json::from_value(user).map_err(|_| AppError::Internal)?;

    // Verify the current master password
    let verification = user
        .verify_master_password(&payload.master_password_hash)
        .await?;

    if !verification.is_valid() {
        return Err(AppError::Unauthorized("Invalid password".to_string()));
    }

    // Generate new salt and hash the new password
    let new_salt = generate_salt()?;
    let password_iterations = server_password_iterations(&env) as i32;
    let new_hashed_password = hash_password_for_storage(
        &payload.new_master_password_hash,
        &new_salt,
        password_iterations as u32,
    )
    .await?;

    // Generate new security stamp and update timestamp
    let new_security_stamp = Uuid::new_v4().to_string();
    let now = db::now_string();

    // Update user record
    d1_query!(
        &db,
        "UPDATE users SET master_password_hash = ?1, password_salt = ?2, password_iterations = ?3, key = ?4, master_password_hint = ?5, security_stamp = ?6, updated_at = ?7 WHERE id = ?8",
        new_hashed_password,
        new_salt,
        password_iterations,
        payload.key,
        payload.master_password_hint,
        new_security_stamp,
        now,
        user_id
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await?;

    notifications::publish_user_logout((*env).clone(), claims.sub, now, Some(claims.device));

    Ok(Json(json!({})))
}

/// POST /accounts/key-management/rotate-user-account-keys - Rotate user encryption keys
#[worker::send]
pub async fn post_rotatekey(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<RotateKeyRequest>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user_id = &claims.sub;
    let batch_size = get_batch_size(&env);

    // Get the user from the database
    let user: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;
    let user: User = serde_json::from_value(user).map_err(|_| AppError::Internal)?;

    // Verify the current master password
    let verification = user
        .verify_master_password(&payload.old_master_key_authentication_hash)
        .await?;

    if !verification.is_valid() {
        return Err(AppError::Unauthorized("Invalid password".to_string()));
    }

    let unlock_data = &payload.account_unlock_data.master_password_unlock_data;

    validate_rotation_metadata(&user, unlock_data, &payload.account_keys.account_public_key)?;

    // Validate KDF parameters
    ensure_supported_kdf(
        unlock_data.kdf_type,
        unlock_data.kdf_iterations,
        unlock_data.kdf_memory,
        unlock_data.kdf_parallelism,
    )?;

    // Validate data integrity using D1 batch operations
    // Step 1: Ensure all personal ciphers have id (required for key rotation)
    // Step 2: Count check - ensure request has exactly the same number of items as DB
    // Step 3: EXCEPT check - ensure request has exactly the same IDs as DB
    let personal_ciphers: Vec<_> = payload
        .account_data
        .ciphers
        .into_iter()
        .filter(|c| c.organization_id.is_none())
        .collect();

    let request_cipher_ids: Vec<String> = personal_ciphers
        .iter()
        .filter_map(|c| c.id.clone())
        .collect();

    // All personal ciphers must have an id for key rotation
    if personal_ciphers.len() != request_cipher_ids.len() {
        log::error!(
            "All ciphers must have an id for key rotation: {:?} != {:?}",
            personal_ciphers.len(),
            request_cipher_ids.len()
        );
        return Err(AppError::BadRequest(
            "All ciphers must have an id for key rotation".to_string(),
        ));
    }

    // Filter out null folder IDs (Bitwarden client bug: https://github.com/bitwarden/clients/issues/8453)
    let request_folder_ids: Vec<String> = payload
        .account_data
        .folders
        .iter()
        .filter_map(|f| f.id.clone())
        .collect();

    let cipher_ids_json =
        serde_json::to_string(&request_cipher_ids).map_err(|_| AppError::Internal)?;
    let folder_ids_json =
        serde_json::to_string(&request_folder_ids).map_err(|_| AppError::Internal)?;

    // Batch: 2 COUNT queries + 2 EXCEPT queries
    let validation_results = db
        .batch(vec![
            // Count ciphers in DB
            db.prepare(
                "SELECT COUNT(*) AS cnt FROM ciphers WHERE user_id = ?1 AND organization_id IS NULL",
            )
            .bind(&[user_id.clone().into()])?,
            // Count folders in DB
            db.prepare("SELECT COUNT(*) AS cnt FROM folders WHERE user_id = ?1")
                .bind(&[user_id.clone().into()])?,
            // DB cipher IDs EXCEPT request cipher IDs (finds missing)
            db.prepare(
                "SELECT id FROM ciphers WHERE user_id = ?1 AND organization_id IS NULL
                 EXCEPT
                 SELECT value FROM json_each(?2) LIMIT 1",
            )
            .bind(&[user_id.clone().into(), cipher_ids_json.into()])?,
            // DB folder IDs EXCEPT request folder IDs (finds missing)
            db.prepare(
                "SELECT id FROM folders WHERE user_id = ?1
                 EXCEPT
                 SELECT value FROM json_each(?2) LIMIT 1",
            )
            .bind(&[user_id.clone().into(), folder_ids_json.into()])?,
        ])
        .await?;

    // Check counts match
    let db_cipher_count = validation_results[0]
        .results::<Value>()?
        .first()
        .and_then(|v| v.get("cnt")?.as_i64())
        .unwrap_or(0) as usize;
    let db_folder_count = validation_results[1]
        .results::<Value>()?
        .first()
        .and_then(|v| v.get("cnt")?.as_i64())
        .unwrap_or(0) as usize;

    if db_cipher_count != request_cipher_ids.len() || db_folder_count != request_folder_ids.len() {
        log::error!(
            "Cipher or folder count mismatch in rotation request: {:?} != {:?} or {:?} != {:?}",
            db_cipher_count,
            request_cipher_ids.len(),
            db_folder_count,
            request_folder_ids.len()
        );
        return Err(AppError::BadRequest(
            "All existing ciphers and folders must be included in the rotation".to_string(),
        ));
    }

    // Check EXCEPT results (if count matches but IDs differ)
    let has_missing_ciphers = !validation_results[2].results::<Value>()?.is_empty();
    let has_missing_folders = !validation_results[3].results::<Value>()?.is_empty();

    if has_missing_ciphers || has_missing_folders {
        log::error!(
            "Missing ciphers or folders in rotation request: {:?} or {:?}",
            has_missing_ciphers,
            has_missing_folders
        );
        return Err(AppError::BadRequest(
            "All existing ciphers and folders must be included in the rotation".to_string(),
        ));
    }

    let now = db::now_string();

    // Update all folders with new encrypted names (batch operation)
    // Skip null folder IDs (Bitwarden client bug: https://github.com/bitwarden/clients/issues/8453)
    let mut folder_statements: Vec<D1PreparedStatement> =
        Vec::with_capacity(payload.account_data.folders.len());
    for folder in &payload.account_data.folders {
        // Skip null folder id entries
        let Some(folder_id) = &folder.id else {
            continue;
        };
        let stmt = d1_query!(
            &db,
            "UPDATE folders SET name = ?1, updated_at = ?2 WHERE id = ?3 AND user_id = ?4",
            folder.name,
            now,
            folder_id,
            user_id
        )
        .map_err(|_| AppError::Database)?;
        folder_statements.push(stmt);
    }
    db::execute_in_batches(&db, folder_statements, batch_size).await?;

    // Update all ciphers with new encrypted data (batch operation)
    // Only update personal ciphers (organization_id is None)
    let mut cipher_statements: Vec<D1PreparedStatement> =
        Vec::with_capacity(personal_ciphers.len());
    let mut attachment_statements: Vec<D1PreparedStatement> = Vec::new();
    for cipher in personal_ciphers {
        // id is guaranteed to exist (validated above)
        let cipher_id = cipher.id.as_ref().unwrap();

        let cipher_data = CipherData::new(cipher.name, cipher.notes, cipher.type_fields);

        let data = serde_json::to_string(&cipher_data).map_err(|_| AppError::Internal)?;

        let stmt = d1_query!(
            &db,
            "UPDATE ciphers SET data = ?1, folder_id = ?2, favorite = ?3, updated_at = ?4 WHERE id = ?5 AND user_id = ?6",
            data,
            cipher.folder_id,
            cipher.favorite.unwrap_or(false),
            now,
            cipher_id,
            user_id
        )
        .map_err(|_| AppError::Database)?;
        cipher_statements.push(stmt);

        // Update attachments key and encrypted filename when rotating.
        // The Bitwarden clients send `attachments2` only during key rotation.
        if let Some(attachments2) = &cipher.attachments2 {
            for (attachment_id, attachment) in attachments2 {
                let stmt = d1_query!(
                    &db,
                    "UPDATE attachments SET file_name = ?1, akey = ?2, updated_at = ?3 WHERE id = ?4 AND cipher_id = ?5",
                    attachment.file_name,
                    attachment.key,
                    now,
                    attachment_id,
                    cipher_id
                )
                .map_err(|_| AppError::Database)?;
                attachment_statements.push(stmt);
            }
        }
    }
    db::execute_in_batches(&db, cipher_statements, batch_size).await?;
    db::execute_in_batches(&db, attachment_statements, batch_size).await?;

    // Rotate sends
    sends::rotate_user_sends(
        &db,
        env.as_ref(),
        user_id,
        &payload.account_data.sends,
        &now,
        batch_size,
    )
    .await?;

    // Generate new salt and hash the new password
    let new_salt = generate_salt()?;
    let password_iterations = server_password_iterations(&env) as i32;
    let new_hashed_password = hash_password_for_storage(
        &unlock_data.master_key_authentication_hash,
        &new_salt,
        password_iterations as u32,
    )
    .await?;

    // Generate new security stamp
    let new_security_stamp = Uuid::new_v4().to_string();

    // Only store kdf_memory and kdf_parallelism for Argon2id, clear for PBKDF2
    let (kdf_memory, kdf_parallelism) = if unlock_data.kdf_type == KDF_TYPE_ARGON2ID {
        (unlock_data.kdf_memory, unlock_data.kdf_parallelism)
    } else {
        (None, None)
    };

    // Update user record with new keys and password
    d1_query!(
        &db,
        "UPDATE users SET master_password_hash = ?1, password_salt = ?2, password_iterations = ?3, key = ?4, private_key = ?5, kdf_type = ?6, kdf_iterations = ?7, kdf_memory = ?8, kdf_parallelism = ?9, security_stamp = ?10, updated_at = ?11 WHERE id = ?12",
        new_hashed_password,
        new_salt,
        password_iterations,
        unlock_data.master_key_encrypted_user_key,
        payload.account_keys.user_key_encrypted_account_private_key,
        unlock_data.kdf_type,
        unlock_data.kdf_iterations,
        kdf_memory,
        kdf_parallelism,
        new_security_stamp,
        now,
        user_id
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await?;

    notifications::publish_user_logout((*env).clone(), claims.sub, now, Some(claims.device));

    Ok(Json(json!({})))
}

/// POST /accounts/kdf - Change KDF settings (PBKDF2 <-> Argon2id)
#[worker::send]
pub async fn post_kdf(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<ChangeKdfRequest>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user_id = &claims.sub;

    // Get the user from the database
    let user: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;
    let user: User = serde_json::from_value(user).map_err(|_| AppError::Internal)?;

    // Verify the current master password
    let verification = user
        .verify_master_password(&payload.master_password_hash)
        .await?;

    if !verification.is_valid() {
        return Err(AppError::Unauthorized("Invalid password".to_string()));
    }

    let auth_data = &payload.authentication_data;
    let unlock_data = &payload.unlock_data;

    if auth_data.kdf != unlock_data.kdf {
        return Err(AppError::BadRequest(
            "KDF settings must be equal for authentication and unlock".to_string(),
        ));
    }

    if user.email != auth_data.salt || user.email != unlock_data.salt {
        return Err(AppError::BadRequest(
            "Invalid master password salt".to_string(),
        ));
    }

    let kdf_type = unlock_data.kdf.kdf;
    let kdf_iterations = unlock_data.kdf.kdf_iterations;
    let kdf_memory = unlock_data.kdf.kdf_memory;
    let kdf_parallelism = unlock_data.kdf.kdf_parallelism;

    ensure_supported_kdf(kdf_type, kdf_iterations, kdf_memory, kdf_parallelism)?;

    // Generate new salt and hash the new password
    let new_salt = generate_salt()?;
    let password_iterations = server_password_iterations(&env) as i32;
    let new_hashed_password = hash_password_for_storage(
        &auth_data.master_password_authentication_hash,
        &new_salt,
        password_iterations as u32,
    )
    .await?;

    let new_security_stamp = Uuid::new_v4().to_string();
    let now = db::now_string();

    // Determine kdf_memory and kdf_parallelism based on KDF type
    let (final_kdf_memory, final_kdf_parallelism) = if kdf_type == KDF_TYPE_ARGON2ID {
        (kdf_memory, kdf_parallelism)
    } else {
        // For PBKDF2, clear these fields
        (None, None)
    };

    d1_query!(
        &db,
        "UPDATE users SET master_password_hash = ?1, password_salt = ?2, password_iterations = ?3, key = ?4, kdf_type = ?5, kdf_iterations = ?6, kdf_memory = ?7, kdf_parallelism = ?8, security_stamp = ?9, updated_at = ?10 WHERE id = ?11",
        new_hashed_password,
        new_salt,
        password_iterations,
        &unlock_data.master_key_wrapped_user_key,
        kdf_type,
        kdf_iterations,
        final_kdf_memory,
        final_kdf_parallelism,
        new_security_stamp,
        now,
        user_id
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await?;

    notifications::publish_user_logout((*env).clone(), claims.sub, now, Some(claims.device));

    Ok(Json(json!({})))
}

/// POST /api/accounts/security-stamp - invalidates all tokens and forces logout
#[worker::send]
pub async fn post_sstamp(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<PasswordOrOtpData>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let user_id = &claims.sub;

    // Load the user to verify credentials
    let user: User = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[user_id.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".to_string()))?;

    // Require master password hash (OTP not supported)
    let provided_hash = payload
        .master_password_hash
        .ok_or_else(|| AppError::BadRequest("Missing master password hash".to_string()))?;

    let verification = user.verify_master_password(&provided_hash).await?;
    if !verification.is_valid() {
        return Err(AppError::Unauthorized("Invalid password".to_string()));
    }

    push::unregister_push_devices_by_user(&env, user_id).await;

    // Delete all device rows — this revokes every refresh token and 2FA-remember token
    Device::delete_all_by_user(&db, user_id).await?;

    // Rotate the security stamp so all existing access tokens become invalid immediately
    let new_security_stamp = Uuid::new_v4().to_string();
    let now = db::now_string();

    d1_query!(
        &db,
        "UPDATE users SET security_stamp = ?1, updated_at = ?2 WHERE id = ?3",
        new_security_stamp,
        now,
        user_id
    )
    .map_err(|_| AppError::Database)?
    .run()
    .await?;

    // Known issue: Logout push for mobile devices will be skiped since the records of devices are deleted.
    // Notifications are sent in background via waitUntil,
    // so putting it ahead of device deletion is not guaranteed to send the logout push before the deletion.
    notifications::publish_user_logout((*env).clone(), claims.sub, now, None);

    Ok(Json(json!({})))
}

fn mail_response(
    to: &str,
    subject: &str,
    text: &str,
) -> Result<axum::response::Response, AppError> {
    use base64::Engine;
    let content = format!("{text}\n\nAZET Pass, AZET LLC");
    let value = base64::engine::general_purpose::STANDARD
        .encode(json!({"to":to,"subject":subject,"text":content}).to_string());
    let mut response = StatusCode::OK.into_response();
    response.headers_mut().insert(
        "x-azet-mail",
        value.parse().map_err(|_| AppError::Internal)?,
    );
    Ok(response)
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PasswordCheck {
    master_password_hash: String,
}

pub(crate) async fn checked_user(db: &crate::db::Db, id: &str, hash: &str) -> Result<User, AppError> {
    let row: Value = db
        .prepare("SELECT * FROM users WHERE id = ?1")
        .bind(&[id.into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".into()))?;
    let user: User = serde_json::from_value(row).map_err(|_| AppError::Internal)?;
    if !user.verify_master_password(hash).await?.is_valid() {
        return Err(AppError::BadRequest("Invalid password.".into()));
    }
    Ok(user)
}

#[worker::send]
pub async fn verify_password(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<PasswordCheck>,
) -> Result<Json<Value>, AppError> {
    checked_user(
        &db::get_db(&env)?,
        &claims.sub,
        &payload.master_password_hash,
    )
    .await?;
    Ok(Json(json!({"object":"masterPasswordPolicy"})))
}

#[worker::send]
pub async fn subscription(
    claims: Claims,
    State(env): State<Arc<Env>>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let row: Value = db
        .prepare("SELECT azet_expires_at FROM users WHERE id = ?1")
        .bind(&[claims.sub.clone().into()])?
        .first(None)
        .await
        .map_err(|_| AppError::Database)?
        .ok_or_else(|| AppError::NotFound("User not found".into()))?;
    let premium = crate::handlers::azet::premium_for(&env, &claims.sub).await;
    Ok(Json(
        json!({"object":"subscription","storageName":null,"storageGb":0.0,
        "maxStorageGb":if premium {Some(1)} else {None},"subscription":null,"upcomingInvoice":null,
        "customerDiscount":null,"license":null,"expiration":row["azet_expires_at"],"usingInAppPurchase":false}),
    ))
}

// HMAC-SHA256, implemented using the existing sha2 crate to avoid additional dependencies.
fn email_code(secret: &str, id: &str, email: &str, window: i64) -> String {
    use sha2::{Digest, Sha256};
    let mut key = [0u8; 64];
    let secret_bytes = secret.as_bytes();
    if secret_bytes.len() > 64 {
        key[..32].copy_from_slice(&Sha256::digest(secret_bytes));
    } else {
        key[..secret_bytes.len()].copy_from_slice(secret_bytes);
    }
    let mut inner = [0x36u8; 64];
    let mut outer = [0x5cu8; 64];
    for i in 0..64 {
        inner[i] ^= key[i];
        outer[i] ^= key[i];
    }
    let payload = format!("pass-email.{id}.{}.{}", email.to_lowercase(), window);
    let first = Sha256::new()
        .chain_update(inner)
        .chain_update(payload)
        .finalize();
    let digest = Sha256::new()
        .chain_update(outer)
        .chain_update(first)
        .finalize();
    format!(
        "{:06}",
        u32::from_be_bytes(digest[..4].try_into().unwrap()) % 1_000_000
    )
}
fn valid_email_code(secret: &str, id: &str, email: &str, code: &str, now: i64) -> bool {
    use constant_time_eq::constant_time_eq;
    let window = now.div_euclid(900);
    [window, window - 1].iter().any(|w| {
        constant_time_eq(
            email_code(secret, id, email, *w).as_bytes(),
            code.as_bytes(),
        )
    })
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EmailTokenRequest {
    new_email: String,
    master_password_hash: String,
}

#[worker::send]
pub async fn email_token(
    claims: Claims,
    State(env): State<Arc<Env>>,
    headers: HeaderMap,
    Json(payload): Json<EmailTokenRequest>,
) -> Result<axum::response::Response, AppError> {
    enforce_ip_rate_limit(
        &env,
        &headers,
        "LOGIN_RATE_LIMITER",
        "email-token",
        "Too many requests",
    )
    .await?;
    let db = db::get_db(&env)?;
    let new_email = payload.new_email.trim().to_lowercase();
    if !new_email.contains('@') || new_email.len() > 254 {
        return Err(AppError::BadRequest("Invalid email.".into()));
    }
    checked_user(&db, &claims.sub, &payload.master_password_hash).await?;
    if User::find_by_email(&db, &new_email).await?.is_some() {
        return Err(AppError::BadRequest("Email already taken.".into()));
    }
    let secret = env.secret("JWT_SECRET")?.to_string();
    let code = email_code(
        &secret,
        &claims.sub,
        &new_email,
        chrono::Utc::now().timestamp().div_euclid(900),
    );
    mail_response(&new_email, "AZET Pass email verification", &format!("Your verification code is {code}. It expires in 15 minutes.\n\n이메일 인증 코드는 {code}입니다. 15분 동안 유효합니다."))
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeEmailData {
    new_email: String,
    master_password_hash: String,
    new_master_password_hash: String,
    token: String,
    key: String,
    master_password_hint: Option<String>,
    kdf: Option<i32>,
    kdf_iterations: Option<i32>,
    kdf_memory: Option<i32>,
    kdf_parallelism: Option<i32>,
}

#[worker::send]
pub async fn change_email(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<ChangeEmailData>,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    let email = payload.new_email.trim().to_lowercase();
    let user = checked_user(&db, &claims.sub, &payload.master_password_hash).await?;
    if !valid_email_code(
        &env.secret("JWT_SECRET")?.to_string(),
        &claims.sub,
        &email,
        &payload.token,
        chrono::Utc::now().timestamp(),
    ) {
        return Err(AppError::BadRequest(
            "Invalid email verification code.".into(),
        ));
    }
    if User::find_by_email(&db, &email).await?.is_some() {
        return Err(AppError::BadRequest("Email already taken.".into()));
    }
    let kdf = payload.kdf.unwrap_or(user.kdf_type);
    let iterations = payload.kdf_iterations.unwrap_or(user.kdf_iterations);
    let memory = payload.kdf_memory.or(user.kdf_memory);
    let parallelism = payload.kdf_parallelism.or(user.kdf_parallelism);
    ensure_supported_kdf(kdf, iterations, memory, parallelism)?;
    let salt = generate_salt()?;
    let password_iterations = server_password_iterations(&env) as i32;
    let hash = hash_password_for_storage(
        &payload.new_master_password_hash,
        &salt,
        password_iterations as u32,
    )
    .await?;
    let stamp = Uuid::new_v4().to_string();
    let now = db::now_string();
    d1_query!(&db,"UPDATE users SET email = ?1, master_password_hash = ?2, password_salt = ?3, password_iterations = ?4, key = ?5, master_password_hint = ?6, kdf_type = ?7, kdf_iterations = ?8, kdf_memory = ?9, kdf_parallelism = ?10, security_stamp = ?11, updated_at = ?12 WHERE id = ?13",
        email,hash,salt,password_iterations,payload.key,payload.master_password_hint,kdf,iterations,memory,parallelism,stamp,now,&claims.sub)
        .map_err(|_| AppError::Database)?.run().await.map_err(|_| AppError::Database)?;
    Device::delete_all_by_user(&db, &claims.sub).await?;
    notifications::publish_user_logout((*env).clone(), claims.sub, now, None);
    Ok(Json(json!({})))
}

async fn api_key_impl(
    claims: Claims,
    env: Arc<Env>,
    payload: PasswordCheck,
    rotate: bool,
) -> Result<Json<Value>, AppError> {
    let db = db::get_db(&env)?;
    checked_user(&db, &claims.sub, &payload.master_password_hash).await?;
    let existing: Option<String> = db
        .prepare("SELECT api_key FROM users WHERE id = ?1")
        .bind(&[claims.sub.clone().into()])?
        .first(Some("api_key"))
        .await
        .map_err(|_| AppError::Database)?;
    let key = if !rotate {
        existing.filter(|s| !s.is_empty())
    } else {
        None
    };
    let key = match key {
        Some(v) => v,
        None => {
            const ALPHABET: &[u8] =
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
            let mut bytes = [0u8; 30];
            getrandom::fill(&mut bytes).map_err(|_| AppError::Internal)?;
            let value: String = bytes
                .iter()
                .map(|n| ALPHABET[(*n as usize) % ALPHABET.len()] as char)
                .collect();
            db.prepare("UPDATE users SET api_key = ?1 WHERE id = ?2")
                .bind(&[value.clone().into(), claims.sub.clone().into()])?
                .run()
                .await
                .map_err(|_| AppError::Database)?;
            value
        }
    };
    let date: Option<String> = db
        .prepare("SELECT updated_at FROM users WHERE id = ?1")
        .bind(&[claims.sub.into()])?
        .first(Some("updated_at"))
        .await
        .map_err(|_| AppError::Database)?;
    Ok(Json(
        json!({"apiKey":key,"revisionDate":date,"object":"apiKey"}),
    ))
}
#[worker::send]
pub async fn api_key(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<PasswordCheck>,
) -> Result<Json<Value>, AppError> {
    api_key_impl(claims, env, payload, false).await
}
#[worker::send]
pub async fn rotate_api_key(
    claims: Claims,
    State(env): State<Arc<Env>>,
    Json(payload): Json<PasswordCheck>,
) -> Result<Json<Value>, AppError> {
    api_key_impl(claims, env, payload, true).await
}

#[cfg(test)]
mod email_code_tests {
    use super::*;
    #[test]
    fn accepts_current_and_previous_windows_only() {
        let secret = "test-secret";
        let id = "user-id";
        let email = "EXAMPLE@EMAIL.COM";
        let now = 2_000_000;
        let window = now / 900;
        assert!(valid_email_code(
            secret,
            id,
            email,
            &email_code(secret, id, email, window),
            now
        ));
        assert!(valid_email_code(
            secret,
            id,
            email,
            &email_code(secret, id, email, window - 1),
            now
        ));
        assert!(!valid_email_code(
            secret,
            id,
            email,
            &email_code(secret, id, email, window - 2),
            now
        ));
    }
}
