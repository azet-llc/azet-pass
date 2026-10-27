//! AZET Pass families (GPL-3.0, AZET LLC 2026): the few organization key operations the iOS app needs and the
//! Bitwarden mobile SDK does not expose (family creation, handing the family key to a confirmed member, organizer
//! recovery). Thin wrappers over bitwarden-crypto, the same primitives `PureCrypto` exposes to the web clients.
#![allow(deprecated)]

use std::str::FromStr;

use bitwarden_core::key_management::KeySlotIds;
use bitwarden_crypto::{
    BitwardenLegacyKeyBytes, CryptoError, Decryptable, EncString, HashPurpose, Kdf, KeyDecryptable, KeyEncryptable,
    KeyStore, MasterKey, Pkcs8PrivateKeyBytes, PrimitiveEncryptable, PrivateKey, PublicKey,
    PublicKeyEncryptionAlgorithm, SpkiPublicKeyBytes, SymmetricCryptoKey, SymmetricKeyAlgorithm,
    UnsignedSharedKey,
};
use bitwarden_encoding::B64;

use crate::error::Result;

fn b64(s: &str) -> Result<Vec<u8>> {
    Ok(B64::try_from(s.to_string()).map_err(|_| CryptoError::InvalidKey)?.into())
}

fn sym(s: &str) -> Result<SymmetricCryptoKey> {
    Ok(SymmetricCryptoKey::try_from(&BitwardenLegacyKeyBytes::from(b64(s)?))?)
}

fn public(s: &str) -> Result<PublicKey> {
    Ok(PublicKey::from_der(&SpkiPublicKeyBytes::from(b64(s)?))?)
}

fn private_with(key: &SymmetricCryptoKey, wrapped: &str) -> Result<PrivateKey> {
    let store: KeyStore<KeySlotIds> = KeyStore::default();
    let mut ctx = store.context();
    let k = ctx.add_local_symmetric_key(key.clone());
    let der: Vec<u8> = EncString::from_str(wrapped)?.decrypt(&mut ctx, k)?;
    Ok(PrivateKey::from_der(&Pkcs8PrivateKeyBytes::from(der))?)
}

#[allow(missing_docs)]
#[derive(uniffi::Record)]
pub struct AzetFamilyKeys {
    /// The family key (base64). Kept in memory only, like the user key.
    pub org_key: String,
    /// The family key wrapped to the organizer's public key (the organizer's `akey`).
    pub owner_key: String,
    pub public_key: String,
    pub encrypted_private_key: String,
    pub encrypted_vault_name: String,
}

#[allow(missing_docs)]
#[derive(uniffi::Record)]
pub struct AzetRecovery {
    pub new_master_password_hash: String,
    pub new_key: String,
}

/// A new family: family key, family key pair, the organizer's wrapped copy and the first shared vault's name.
#[uniffi::export]
pub fn azet_family_make(owner_public_key: String, first_vault_name: String) -> Result<AzetFamilyKeys> {
    let org_key = SymmetricCryptoKey::make(SymmetricKeyAlgorithm::Aes256CbcHmac);
    let pair = PrivateKey::make(PublicKeyEncryptionAlgorithm::RsaOaepSha1);
    let public_der = pair.to_public_key().to_der()?;
    let store: KeyStore<KeySlotIds> = KeyStore::default();
    let mut ctx = store.context();
    let k = ctx.add_local_symmetric_key(org_key.clone());
    let encrypted_private_key = Pkcs8PrivateKeyBytes::from(pair.to_der()?.to_vec()).encrypt(&mut ctx, k)?.to_string();
    Ok(AzetFamilyKeys {
        owner_key: UnsignedSharedKey::encapsulate_key_unsigned(&org_key, &public(&owner_public_key)?)?.to_string(),
        public_key: B64::from(public_der.as_ref()).to_string(),
        encrypted_private_key,
        encrypted_vault_name: first_vault_name.encrypt_with_key(&org_key)?.to_string(),
        org_key: B64::from(org_key.to_encoded().to_vec()).to_string(),
    })
}

/// The family key wrapped to a member's public key (organizer confirms a member).
#[uniffi::export]
pub fn azet_family_wrap(org_key: String, member_public_key: String) -> Result<String> {
    Ok(UnsignedSharedKey::encapsulate_key_unsigned(&sym(&org_key)?, &public(&member_public_key)?)?.to_string())
}

/// The family key from the member's `akey`, with the member's user key and their wrapped private key.
#[uniffi::export]
pub fn azet_family_unwrap(user_key: String, user_private_key: String, akey: String) -> Result<String> {
    let private = private_with(&sym(&user_key)?, &user_private_key)?;
    let org = UnsignedSharedKey::from_str(&akey)?.decapsulate_key_unsigned(&private)?;
    Ok(B64::from(org.to_encoded().to_vec()).to_string())
}

/// Vault names and other family strings.
#[uniffi::export]
pub fn azet_family_encrypt(org_key: String, plain: String) -> Result<String> {
    Ok(plain.encrypt_with_key(&sym(&org_key)?)?.to_string())
}

/// Reverse of [azet_family_encrypt].
#[uniffi::export]
pub fn azet_family_decrypt(org_key: String, enc: String) -> Result<String> {
    Ok(EncString::from_str(&enc)?.decrypt_with_key(&sym(&org_key)?)?)
}

/// Organizer recovery: the member's user key (wrapped to the family public key when they joined) re-wrapped with
/// a temporary account password the organizer gives them. The vault itself is untouched.
#[uniffi::export]
pub fn azet_family_recover(
    org_key: String,
    org_encrypted_private_key: String,
    reset_password_key: String,
    email: String,
    new_password: String,
    kdf: Kdf,
) -> Result<AzetRecovery> {
    let org_private = private_with(&sym(&org_key)?, &org_encrypted_private_key)?;
    let user_key = UnsignedSharedKey::from_str(&reset_password_key)?.decapsulate_key_unsigned(&org_private)?;
    let master = MasterKey::derive(&new_password, &email, &kdf)?;
    Ok(AzetRecovery {
        new_master_password_hash: master.derive_master_key_hash(new_password.as_bytes(), HashPurpose::ServerAuthorization).to_string(),
        new_key: master.encrypt_user_key(&user_key)?.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn family_round_trip() {
        let member = PrivateKey::make(PublicKeyEncryptionAlgorithm::RsaOaepSha1);
        let member_pub = B64::from(member.to_public_key().to_der().unwrap().as_ref()).to_string();
        let user_key = SymmetricCryptoKey::make(SymmetricKeyAlgorithm::Aes256CbcHmac);
        let user_key_b64 = B64::from(user_key.to_encoded().to_vec()).to_string();
        let wrapped_private = Pkcs8PrivateKeyBytes::from(member.to_der().unwrap().to_vec());
        let store: KeyStore<KeySlotIds> = KeyStore::default();
        let mut ctx = store.context();
        let uk = ctx.add_local_symmetric_key(user_key.clone());
        let wrapped_private = wrapped_private.encrypt(&mut ctx, uk).unwrap().to_string();

        let fam = azet_family_make(member_pub.clone(), "가족 공유".into()).unwrap();
        assert_eq!(azet_family_decrypt(fam.org_key.clone(), fam.encrypted_vault_name.clone()).unwrap(), "가족 공유");
        assert_eq!(azet_family_unwrap(user_key_b64.clone(), wrapped_private.clone(), fam.owner_key.clone()).unwrap(), fam.org_key);
        let akey = azet_family_wrap(fam.org_key.clone(), member_pub).unwrap();
        assert_eq!(azet_family_unwrap(user_key_b64, wrapped_private, akey).unwrap(), fam.org_key);

        // recovery: user key wrapped to the family public key comes back under a new password
        let reset = UnsignedSharedKey::encapsulate_key_unsigned(&user_key, &public(&fam.public_key).unwrap()).unwrap().to_string();
        let kdf = Kdf::PBKDF2 { iterations: std::num::NonZeroU32::new(5000).unwrap() };
        let r = azet_family_recover(fam.org_key, fam.encrypted_private_key, reset, "mom@x.test".into(), "temp-pass-1".into(), kdf.clone()).unwrap();
        let back = MasterKey::derive("temp-pass-1", "mom@x.test", &kdf).unwrap().decrypt_user_key(EncString::from_str(&r.new_key).unwrap()).unwrap();
        assert_eq!(back.to_encoded().to_vec(), user_key.to_encoded().to_vec());
    }
}
