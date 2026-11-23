# sdk-internal patches used by the AZET Pass apps

Base: bitwarden/sdk-internal 9794da58 (GPL-3.0). `0001-azet-uniffi-helpers.patch` adds the azet_* UniFFI functions
(JSON <-> Cipher/Send, family key unwrap) that the iPhone and Android apps call. Apply: `git apply 0001-azet-uniffi-helpers.patch`.
