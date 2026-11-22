use axum::{
    http::header,
    response::{IntoResponse, Response},
};

/// Per-site sign-in selectors (Samsung Pass's 자동완성 정책) for AZET Browser: the account, password, code and submit
/// fields of a login page, by host. Checked against each live page; AZET Browser falls back to reading the form.
const RECIPES: &str = include_str!("../../login-recipes.json");

/// GET /api/login-recipes
#[worker::send]
pub async fn login_recipes() -> Response {
    (
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "public, max-age=86400"),
        ],
        RECIPES,
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    #[test]
    fn recipes_are_valid_json_with_hosts() {
        let v: serde_json::Value = serde_json::from_str(super::RECIPES).expect("login-recipes.json parses");
        let r = v["recipes"].as_object().expect("recipes object");
        assert!(r.contains_key("nid.naver.com"));
        assert!(r.values().all(|x| x.is_object()));
    }
}
