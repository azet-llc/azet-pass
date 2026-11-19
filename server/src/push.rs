//! Push to phones. The server sends straight to Google (FCM v1) for Android and to Apple (APNs) for iPhone; there is
//! no relay in between. A message carries only the kind of change, ids and dates: the app then asks this server for
//! what changed, so Google and Apple never see vault content. Nothing is sent unless the secrets are set:
//!   FCM_SERVICE_ACCOUNT   the Firebase service account (JSON)                              -> Android
//!   APNS_KEY, APNS_KEY_ID, APNS_TEAM_ID, APNS_TOPIC   the .p8 key (PEM), its id, team, bundle id   -> iPhone
//! FCM_BASE and APNS_BASE replace the two hosts (tests).

use serde_json::{json, Value};
use worker::{wasm_bindgen::JsValue, Cache, Env, Fetch, Headers, Method, Request, RequestInit, Response};

use crate::{crypto, db, error::AppError};

// shortcut: one change reaches at most this many phones (each is one outgoing request of the Worker's budget);
// raise it, or send through a queue, when a shared vault has more members' phones than this.
const MOST_DEVICES: usize = 30;

fn setting(env: &Env, name: &str) -> Option<String> {
    env.secret(name).map(|v| v.to_string()).ok().or_else(|| env.var(name).map(|v| v.to_string()).ok()).filter(|v| !v.is_empty())
}

async fn post(url: &str, headers: &[(&str, &str)], body: String) -> Result<(u16, String), AppError> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post).with_body(Some(JsValue::from_str(&body)));
    let mut req = Request::new_with_init(url, &init).map_err(AppError::Worker)?;
    for (name, value) in headers {
        req.headers_mut().map_err(AppError::Worker)?.set(name, value).map_err(AppError::Worker)?;
    }
    let mut res = Fetch::Request(req).send().await.map_err(AppError::Worker)?;
    Ok((res.status_code(), res.text().await.unwrap_or_default()))
}

/// A sender's token, made at most once per `seconds` (Apple refuses tokens that are made anew for every message).
async fn cached<F: std::future::Future<Output = Result<String, AppError>>>(name: &str, seconds: u32, make: F) -> Result<String, AppError> {
    let url = format!("https://push-token.internal/{name}");
    let cache = Cache::default();
    if let Some(mut hit) = cache.get(&url, false).await.map_err(AppError::Worker)? {
        if let Ok(token) = hit.text().await {
            if !token.is_empty() {
                return Ok(token);
            }
        }
    }
    let token = make.await?;
    let headers = Headers::new();
    headers.set("Cache-Control", &format!("max-age={seconds}")).map_err(AppError::Worker)?;
    let _ = cache.put(&url, Response::ok(&token).map_err(AppError::Worker)?.with_headers(headers)).await;
    Ok(token)
}

fn now() -> i64 {
    chrono::Utc::now().timestamp()
}

async fn google_token(account: &Value) -> Result<String, AppError> {
    let field = |k: &str| account.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_string();
    let (email, uri) = (field("client_email"), field("token_uri"));
    cached(&format!("google/{email}"), 3000, async {
        let claims = json!({ "iss": email, "scope": "https://www.googleapis.com/auth/firebase.messaging", "aud": uri, "iat": now(), "exp": now() + 3600 });
        let jwt = crypto::sign_jwt(false, &field("private_key"), &json!({ "alg": "RS256", "typ": "JWT" }), &claims).await?;
        let (status, body) = post(&uri, &[("content-type", "application/x-www-form-urlencoded")],
            format!("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={jwt}")).await?;
        serde_json::from_str::<Value>(&body).ok().and_then(|v| v.get("access_token").and_then(|t| t.as_str()).map(String::from))
            .ok_or_else(|| { log::error!("push: Google gave no token ({status})"); AppError::Internal })
    }).await
}

/// Sends one change to a phone. `Ok(false)`: Google or Apple says that phone no longer has the app.
async fn send_one(env: &Env, ios: bool, token: &str, kind: i32, payload: &str, context_id: Option<&str>) -> Result<bool, AppError> {
    let (status, body) = if ios {
        let (Some(key), Some(key_id), Some(team), Some(topic)) = (setting(env, "APNS_KEY"), setting(env, "APNS_KEY_ID"), setting(env, "APNS_TEAM_ID"), setting(env, "APNS_TOPIC")) else { return Ok(true) };
        let jwt = cached(&format!("apple/{key_id}"), 2400, async {
            crypto::sign_jwt(true, &key, &json!({ "alg": "ES256", "kid": key_id }), &json!({ "iss": team, "iat": now() })).await
        }).await?;
        let base = setting(env, "APNS_BASE").unwrap_or_else(|| "https://api.push.apple.com".into());
        // shortcut: every message is a silent one (the app syncs, and shows a sign-in request itself); send an alert
        // for sign-in requests when they must show while the app is not running.
        let message = json!({ "aps": { "content-available": 1 }, "data": { "type": kind, "payload": payload, "contextId": context_id } });
        post(&format!("{base}/3/device/{token}"),
            &[("authorization", &format!("bearer {jwt}")), ("apns-topic", &topic), ("apns-push-type", "background"), ("apns-priority", "5")], message.to_string()).await?
    } else {
        let Some(account) = setting(env, "FCM_SERVICE_ACCOUNT").and_then(|s| serde_json::from_str::<Value>(&s).ok()) else { return Ok(true) };
        let bearer = google_token(&account).await?;
        let base = setting(env, "FCM_BASE").unwrap_or_else(|| "https://fcm.googleapis.com".into());
        let project = account.get("project_id").and_then(|v| v.as_str()).unwrap_or_default();
        let mut data = json!({ "type": kind.to_string(), "payload": payload });
        if let Some(id) = context_id {
            data["contextId"] = id.into();
        }
        let message = json!({ "message": { "token": token, "data": data, "android": { "priority": "high" } } });
        post(&format!("{base}/v1/projects/{project}/messages:send"),
            &[("authorization", &format!("Bearer {bearer}")), ("content-type", "application/json")], message.to_string()).await?
    };
    if status == 410 || (status == 404 && body.contains("UNREGISTERED")) {
        return Ok(false);
    }
    if !(200..300).contains(&status) {
        log::warn!("push: {} answered {status}: {}", if ios { "Apple" } else { "Google" }, body.chars().take(200).collect::<String>());
    }
    Ok(true)
}

/// Tells the phones of `users` about a change, except the phone that made it. `payload` gets each phone's own
/// `userId` (the apps drop a message that is not for the signed-in account). A failure here never fails the change.
pub async fn notify(env: &Env, users: &[String], kind: i32, payload: Value, context_id: Option<&str>) {
    if users.is_empty() || (setting(env, "FCM_SERVICE_ACCOUNT").is_none() && setting(env, "APNS_KEY").is_none()) {
        return;
    }
    let Ok(db) = db::get_db_unconstrained(env) else { return };
    let marks = (1..=users.len()).map(|i| format!("?{i}")).collect::<Vec<_>>().join(",");
    let binds: Vec<JsValue> = users.iter().map(|u| u.as_str().into()).collect();
    let Ok(query) = db.prepare(&format!("SELECT identifier, user_id, type, push_token FROM devices WHERE user_id IN ({marks}) AND push_token IS NOT NULL AND type IN (0, 1) LIMIT {MOST_DEVICES}")).bind(&binds) else { return };
    let rows = query.all().await.ok().and_then(|r| r.results::<Value>().ok()).unwrap_or_default();
    for row in rows {
        let text = |k: &str| row.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_string();
        let (device, user, token) = (text("identifier"), text("user_id"), text("push_token"));
        if context_id == Some(device.as_str()) {
            continue;
        }
        let mut own = payload.clone();
        own["userId"] = user.as_str().into();
        let ios = row.get("type").and_then(|v| v.as_f64()) == Some(1.0);
        match send_one(env, ios, &token, kind, &own.to_string(), context_id).await {
            Ok(false) => {
                if let Ok(q) = db.prepare("UPDATE devices SET push_token = NULL WHERE identifier = ?1 AND user_id = ?2").bind(&[device.into(), user.into()]) {
                    let _ = q.run().await;
                }
            }
            Ok(true) => {}
            Err(e) => log::warn!("push: not sent: {e}"),
        }
    }
}
