//! AZET Pass (GPL-3.0, AZET LLC 2026): server JSON in and out of the SDK's encrypted models, through the SDK's own
//! API-model conversions, so the iOS app does not hand-map every cipher field.
use bitwarden_api_api::models::{
    CipherDetailsResponseModel, CipherRequestModel, CollectionDetailsResponseModel, FolderResponseModel,
};
use bitwarden_collections::collection::Collection;
use bitwarden_crypto::CryptoError;
use bitwarden_api_api::models::{SendResponseModel, SendWithIdRequestModel};
use bitwarden_send::Send;
use bitwarden_vault::{Cipher, EncryptionContext, Folder};
use serde_json::Value;

use crate::error::Result;

fn list<T: serde::de::DeserializeOwned>(json: &str, key: &str) -> Result<Vec<T>> {
    let v: Value = serde_json::from_str(json).map_err(|_| CryptoError::InvalidKey)?;
    let items = match v.get(key) {
        Some(Value::Array(a)) => a.clone(),
        _ => match v {
            Value::Array(a) => a,
            other => vec![other],
        },
    };
    // an item the SDK cannot read is skipped, not fatal for the whole vault
    Ok(items.into_iter().filter_map(|i| serde_json::from_value(i).ok()).collect())
}

/// Ciphers from a /api/sync body (key `ciphers`), a list body, or one cipher object.
#[uniffi::export]
pub fn azet_ciphers_from_json(json: String) -> Result<Vec<Cipher>> {
    Ok(list::<CipherDetailsResponseModel>(&json, "ciphers")?.into_iter().filter_map(|m| Cipher::try_from(m).ok()).collect())
}

/// Collections (shared vaults) from a /api/sync body.
#[uniffi::export]
pub fn azet_collections_from_json(json: String) -> Result<Vec<Collection>> {
    Ok(list::<CollectionDetailsResponseModel>(&json, "collections")?.into_iter().filter_map(|m| Collection::try_from(m).ok()).collect())
}

/// Folders from a /api/sync body.
#[uniffi::export]
pub fn azet_folders_from_json(json: String) -> Result<Vec<Folder>> {
    Ok(list::<FolderResponseModel>(&json, "folders")?.into_iter().filter_map(|m| Folder::try_from(m).ok()).collect())
}

/// The request body for POST /api/ciphers, PUT /api/ciphers/{id} and the `cipher` of /api/ciphers/create.
#[uniffi::export]
pub fn azet_cipher_request_json(ctx: EncryptionContext) -> Result<String> {
    Ok(serde_json::to_string(&CipherRequestModel::from(ctx)).map_err(|_| CryptoError::InvalidKey)?)
}

/// A Send (share link) from a /api/sends response.
#[uniffi::export]
pub fn azet_send_from_json(json: String) -> Result<Send> {
    let m: SendResponseModel = serde_json::from_str(&json).map_err(|_| CryptoError::InvalidKey)?;
    Ok(Send::try_from(m).map_err(|_| CryptoError::InvalidKey)?)
}

/// The request body for POST /api/sends.
#[uniffi::export]
pub fn azet_send_request_json(send: Send) -> Result<String> {
    Ok(serde_json::to_string(&SendWithIdRequestModel::from(send)).map_err(|_| CryptoError::InvalidKey)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    // shape of an AZET Pass /api/sync body (server/src/handlers/ciphers.rs cipher_json_expr, family.rs)
    const SYNC: &str = r#"{"ciphers":[{"object":"cipherDetails","id":"0b5e0f6c-6b39-4c8e-9a1c-1f1f1f1f1f1f","userId":null,
      "organizationId":"1c5e0f6c-6b39-4c8e-9a1c-1f1f1f1f1f1f","folderId":null,"type":1,"favorite":false,"edit":true,
      "viewPassword":true,"travelSafe":false,"permissions":{"delete":true,"restore":true},"organizationUseTotp":true,
      "collectionIds":["2c5e0f6c-6b39-4c8e-9a1c-1f1f1f1f1f1f"],"revisionDate":"2026-10-27T09:00:00.000Z",
      "creationDate":"2026-10-27T09:00:00.000Z","deletedDate":null,"archivedDate":null,"attachments":null,
      "name":"2.AAAAAAAAAAAAAAAAAAAAAA==|AAAAAAAAAAAAAAAAAAAAAA==|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      "notes":null,"login":{"username":null,"password":null,"uris":[],"totp":null},"fields":null,"passwordHistory":null,
      "reprompt":0,"key":null}],
      "collections":[{"object":"collectionDetails","id":"2c5e0f6c-6b39-4c8e-9a1c-1f1f1f1f1f1f","organizationId":"1c5e0f6c-6b39-4c8e-9a1c-1f1f1f1f1f1f",
      "name":"2.AAAAAAAAAAAAAAAAAAAAAA==|AAAAAAAAAAAAAAAAAAAAAA==|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=","externalId":null,"type":0,
      "readOnly":false,"hidePasswords":false,"manage":true,"travelSafe":false}],"folders":[]}"#;

    #[test]
    fn reads_azet_sync() {
        let c = azet_ciphers_from_json(SYNC.into()).unwrap();
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].collection_ids.len(), 1);
        assert!(c[0].organization_id.is_some());
        assert_eq!(azet_collections_from_json(SYNC.into()).unwrap().len(), 1);
    }
}
