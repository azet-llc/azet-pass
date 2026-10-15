//! AZET glue: Premium comes from an AZET licence key (CONTRACT.md, product `pass`), not from Bitwarden billing.
//! One seat per account: the account id is the `device_id`, platform `account`.
//! The key is stored so the server can re-check it once a day; it unlocks Premium only and opens no vault data.
use axum::{body::Bytes, extract::State, Json};
use chrono::{DateTime, Duration, Utc};
use serde_json::{json, Value};
use std::sync::Arc;
use worker::{Env, Fetch, Method, Request, RequestInit};

use crate::{auth::Claims, db, error::AppError};

const DEFAULT_SUITE_API: &str = "https://suite-api.azet.io";
const OFFLINE_GRACE_DAYS: i64 = 7; // CONTRACT "Client rules": a cached answer counts for 7 days
const RECHECK_HOURS: i64 = 24; // and is refreshed at most once a day

/// Premium if the last licence answer was active/trial, not past its end, and not older than the 7-day grace.
pub fn premium_from(
    status: Option<&str>,
    expires_at: Option<&str>,
    checked_at: Option<&str>,
    now: DateTime<Utc>,
) -> bool {
    let parse = |s: &str| {
        DateTime::parse_from_rfc3339(s)
            .ok()
            .map(|d| d.with_timezone(&Utc))
    };
    let fresh = checked_at
        .and_then(parse)
        .is_some_and(|c| now - c < Duration::days(OFFLINE_GRACE_DAYS));
    let live = match expires_at {
        None | Some("") => true, // lifetime
        Some(e) => parse(e).is_some_and(|e| e > now),
    };
    matches!(status, Some("active") | Some("trial")) && live && fresh
}

pub fn user_premium(row: &Value) -> bool {
    let s = |k: &str| row.get(k).and_then(|v| v.as_str());
    premium_from(
        s("azet_status"),
        s("azet_expires_at"),
        s("azet_checked_at"),
        Utc::now(),
    )
}

/// Looks the account's licence state up, re-validating with the licence service when the cache is a day old.
pub async fn premium_for(env: &Env, user_id: &str) -> bool {
    let Ok(db) = db::get_db(env) else {
        return false;
    };
    let Ok(q) = db
        .prepare("SELECT azet_license, azet_status, azet_expires_at, azet_checked_at FROM users WHERE id = ?1")
        .bind(&[user_id.into()])
    else {
        return false;
    };
    let Ok(Some(row)) = q.first::<Value>(None).await else {
        return false;
    };
    let key = row
        .get("azet_license")
        .and_then(|v| v.as_str())
        .unwrap_or("");
    let stale = row
        .get("azet_checked_at")
        .and_then(|v| v.as_str())
        .and_then(|c| DateTime::parse_from_rfc3339(c).ok())
        .map_or(true, |c| {
            Utc::now() - c.with_timezone(&Utc) > Duration::hours(RECHECK_HOURS)
        });
    if !key.is_empty() && stale {
        // A failed check does not move "last checked" (CONTRACT), so the grace runs from the last good answer.
        if let Ok((200, body)) = suite(
            env,
            "validate",
            json!({"product": "pass", "device_id": user_id, "license_key": key}),
        )
        .await
        {
            store(env, user_id, Some(key), &body).await;
            return premium_from(
                body["status"].as_str(),
                body["expires_at"].as_str(),
                Some(&db::now_string()),
                Utc::now(),
            );
        }
    }
    user_premium(&row)
}

async fn suite(env: &Env, path: &str, body: Value) -> Result<(u16, Value), AppError> {
    let base = env
        .var("SUITE_API_URL")
        .map(|v| v.to_string())
        .unwrap_or_else(|_| DEFAULT_SUITE_API.into());
    let mut init = RequestInit::new();
    init.with_method(Method::Post)
        .with_body(Some(body.to_string().into()));
    let mut req = Request::new_with_init(&format!("{base}/suite/v1/{path}"), &init)?;
    req.headers_mut()?.set("Content-Type", "application/json")?;
    let mut res = Fetch::Request(req).send().await?;
    let status = res.status_code();
    Ok((status, res.json::<Value>().await.unwrap_or(Value::Null)))
}

async fn store(env: &Env, user_id: &str, key: Option<&str>, body: &Value) {
    if let Ok(db) = db::get_db(env) {
        let status = body["status"].as_str().unwrap_or("none").to_string();
        let expires = body["expires_at"].as_str().map(str::to_string);
        let q = db
            .prepare("UPDATE users SET azet_license = ?1, azet_status = ?2, azet_expires_at = ?3, azet_checked_at = ?4 WHERE id = ?5")
            .bind(&[key.into(), status.into(), expires.into(), db::now_string().into(), user_id.into()]);
        if let Ok(q) = q {
            let _ = q.run().await;
        }
    }
}

/// POST /api/accounts/license — the self-hosted "Premium" page uploads a licence file here.
/// Any upload (file or plain text) containing an AZET key works; the key is activated for this account.
#[worker::send]
pub async fn post_license(
    claims: Claims,
    State(env): State<Arc<Env>>,
    body: Bytes,
) -> Result<Json<Value>, AppError> {
    let text = String::from_utf8_lossy(&body).to_uppercase();
    let key = text
        .split(|c: char| !(c.is_ascii_alphanumeric() || c == '-'))
        .find(|w| w.len() == 28 && w.starts_with("AZET-"))
        .ok_or_else(|| AppError::BadRequest("This key was not recognised. Keys look like AZET-XXXXX-XXXXX-XXXXX-XXXXX. Check it against your order email.".into()))?
        .to_string();
    let (status, answer) = suite(
        &env,
        "activate",
        json!({"license_key": key, "product": "pass", "device_id": claims.sub, "device_name": "AZET Pass account", "platform": "account"}),
    )
    .await
    .map_err(|_| AppError::BadRequest("The license server could not be reached. Nothing was changed. Check the connection and try again.".into()))?;
    if status != 200 {
        return Err(AppError::BadRequest(contract_sentence(
            answer["error"].as_str().unwrap_or("unknown"),
        )));
    }
    store(&env, &claims.sub, Some(&key), &answer).await;
    Ok(Json(
        json!({"ok": true, "status": answer["status"], "plan": answer["plan"], "expires_at": answer["expires_at"]}),
    ))
}

/// Frees the account's seat when the account is deleted (never refused by the licence service).
pub async fn release_seat(env: &Env, user_id: &str) {
    let _ = suite(
        env,
        "deactivate",
        json!({"product": "pass", "device_id": user_id}),
    )
    .await;
}

/// POST /api/accounts/key-management/user-key-id — 2026.9 clients backfill a key id; nothing on this server reads it.
#[worker::send]
pub async fn post_user_key_id(_claims: Claims) -> Result<Json<Value>, AppError> {
    Ok(Json(json!({})))
}

// CONTRACT.md "When activating": one sentence per answer.
fn contract_sentence(code: &str) -> String {
    match code {
        "invalid_key" => "This key was not recognised. Keys look like AZET-XXXXX-XXXXX-XXXXX-XXXXX. Check it against your order email.".into(),
        "wrong_product" => "This key is for another AZET product. Use the key from your AZET Pass or AZET One order.".into(),
        "seat_limit" => "This key is in use on all of its accounts. Release one at azet.io/devices and this account is activated.".into(),
        "expired" => "This license has ended, so it was not activated. Renew it on azet.io, then enter the key again.".into(),
        "revoked" => "This license was cancelled, for example after a refund. If that is a mistake, write to hello@azet.io.".into(),
        "rate_limited" => "Too many attempts from this network. Nothing was changed. Try again later.".into(),
        c => format!("The license server answered with an error ({c}). Nothing was changed. Try again in a moment."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn premium_rules() {
        let now = DateTime::parse_from_rfc3339("2026-10-06T00:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let fresh = Some("2026-10-05T00:00:00Z");
        assert!(premium_from(Some("active"), None, fresh, now)); // lifetime
        assert!(premium_from(
            Some("active"),
            Some("2027-01-01T00:00:00Z"),
            fresh,
            now
        ));
        assert!(!premium_from(
            Some("active"),
            Some("2026-10-01T00:00:00Z"),
            fresh,
            now
        )); // ended
        assert!(!premium_from(Some("expired"), None, fresh, now));
        assert!(!premium_from(None, None, None, now)); // free plan
        assert!(premium_from(
            Some("active"),
            None,
            Some("2026-09-30T00:00:00Z"),
            now
        )); // offline, day 6
        assert!(!premium_from(
            Some("active"),
            None,
            Some("2026-09-28T00:00:00Z"),
            now
        )); // offline past 7 days
    }
}

/// GET /icons/{domain}/icon.png — website icons for vault items. Bitwarden runs its own icon service; we fetch the
/// icon from DuckDuckGo's public favicon service and return it from our own host (clients only allow images from the
/// configured icons URL). The domain is the only input and is already public; no account data is involved.
#[worker::send]
pub async fn icon(
    axum::extract::Path(domain): axum::extract::Path<String>,
) -> axum::response::Response {
    use axum::{http::StatusCode, response::IntoResponse};
    let ok = !domain.is_empty()
        && domain.len() <= 253
        && domain.contains('.')
        && domain
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-');
    if !ok {
        return StatusCode::NOT_FOUND.into_response();
    }
    let Ok(req) = Request::new(
        &format!("https://icons.duckduckgo.com/ip3/{domain}.ico"),
        Method::Get,
    ) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match Fetch::Request(req).send().await {
        Ok(mut r) if r.status_code() == 200 => match r.bytes().await {
            Ok(b) if !b.is_empty() && b.len() <= 100_000 => (
                [
                    ("content-type", "image/x-icon"),
                    ("cache-control", "public, max-age=604800"),
                ],
                b,
            )
                .into_response(),
            _ => StatusCode::NOT_FOUND.into_response(),
        },
        _ => StatusCode::NOT_FOUND.into_response(),
    }
}

/// GET /api/plans/premium — the Premium page reads its price and storage here.
/// Price = catalog.json `pass-yearly` (USD 18.99); storage 1 GB as Bitwarden Premium. No Stripe: the id names the AZET plan.
#[worker::send]
pub async fn premium_plan() -> Json<Value> {
    Json(json!({
        "seat": {"stripePriceId": "azet:pass-yearly", "price": 18.99, "provided": 1},
        "storage": {"stripePriceId": "azet:storage", "price": 0, "provided": 1},
        "object": "premiumPlan"
    }))
}
