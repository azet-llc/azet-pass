# AZET Pass — Google Play release dossier

Status: preparation, not submitted. Checked 2026-10-16 (KST). Publisher identity and the submission slot are owned by lane 449/446; Apple releases are owned by lane 416. Do not treat a verified APK or drafted listing as a Play release.

## Product and reference

AZET Pass is an individual password manager built from the GPL-3.0 Bitwarden Android client. It syncs to `https://pass.azet.io`, an AZET Cloudflare service. It is not a VPN, antivirus, enterprise password manager or Bitwarden-operated service. AZET-specific differences: default server, branding, free TOTP, no organizations/SSO/emergency access; no upgrade purchase buttons in this build. Do not reuse Bitwarden's audit, enterprise or security-key sign-in claims.

Reference inspected: [Bitwarden's live Play listing](https://play.google.com/store/apps/details?id=com.x8bit.bitwarden&hl=en), especially password/passkey positioning and the Accessibility disclosure. Our existing upstream implementation supplies Android Autofill, biometric unlock and Credential Provider integration; no WebView wrapper was added. A device walkthrough still has to establish the actual supported Android/version combinations.

## Store text — en-US

**Title:** AZET Pass: Password Manager

**Short description:** Save passwords, fill logins and keep verification codes in an encrypted vault.

**Full description:**

Keep your passwords and verification codes together with AZET Pass. Save logins, create strong passwords and sync your encrypted vault across your devices.

Use Android Autofill to enter saved logins in supported apps and websites. Unlock your vault with biometrics on compatible devices. Store and use website passkeys where supported by your Android version and the website.

Your vault is encrypted on your device before it syncs to pass.azet.io. Keep your master password safe: AZET cannot recover it. An email address and an AZET Pass account are required for our sync service.

AZET Pass is designed for individuals. Organization management, enterprise SSO and emergency access are not included. This release does not offer in-app purchases.

Optional Accessibility service: you may enable this to help fill logins where Android Autofill does not work. It reads the current screen's login fields to identify a matching app or website and enters the credentials you select. Screen information read by this service is not stored. It does not control other screen actions. You can decline it and keep using the vault, or disable it in Android settings.

AZET Pass uses Bitwarden's GPL-3.0 open-source client code with AZET changes. It is not affiliated with or endorsed by Bitwarden Inc. Source code and license notices: https://github.com/neulketing/azet-pass

Support: hello@azet.io
Privacy: https://azet.io/privacy

## Store text — ko-KR (review draft)

**제목:** AZET Pass: 비밀번호 관리

**짧은 설명:** 비밀번호와 인증 코드를 암호화된 금고에 보관하고 로그인할 때 자동으로 입력하세요.

**상세 설명:**

AZET Pass에서 비밀번호와 인증 코드를 함께 관리하세요. 로그인 정보를 저장하고, 강력한 비밀번호를 만들고, 암호화된 금고를 여러 기기에서 동기화할 수 있습니다.

지원하는 앱과 웹사이트에서는 Android 자동 완성으로 로그인 정보를 입력합니다. 호환 기기에서는 생체 인증으로 금고를 열 수 있으며, Android 버전과 웹사이트가 지원하면 웹사이트용 패스키를 저장하고 사용할 수 있습니다.

금고는 기기에서 암호화된 뒤 pass.azet.io로 동기화됩니다. 마스터 비밀번호는 AZET에서도 복구할 수 없으니 안전하게 보관하세요. AZET 동기화 서비스를 이용하려면 이메일 주소와 AZET Pass 계정이 필요합니다.

개인 사용자를 위한 앱으로, 조직 관리·기업용 SSO·긴급 접근 기능은 포함하지 않습니다. 이 버전에서는 앱 내 구매를 제공하지 않습니다.

선택 접근성 서비스: Android 자동 완성이 작동하지 않는 곳에서 로그인 입력을 돕습니다. 사용자가 켜면 현재 화면의 로그인 입력란을 읽어 앱 또는 웹사이트를 확인하고, 선택한 로그인 정보를 입력합니다. 서비스가 읽은 화면 정보는 저장하지 않으며 로그인 정보 입력 외의 화면 동작을 제어하지 않습니다. 허용하지 않아도 금고를 사용할 수 있고 Android 설정에서 언제든 끌 수 있습니다.

Bitwarden의 GPL-3.0 오픈소스 클라이언트에 AZET 변경 사항을 적용했습니다. Bitwarden Inc.와 제휴 관계가 아니며 해당 회사의 보증을 받지 않습니다. 소스와 라이선스: https://github.com/neulketing/azet-pass

문의: hello@azet.io
개인정보 처리방침: https://azet.io/privacy

## Binary, source and signing

| Field | Observed value |
|---|---|
| Package | `io.azet.pass` |
| Release | `2026.9.1-azet4`, versionCode `20260904` |
| SDK | min 29, target/compile 37 |
| ABI | arm64-v8a only; no 32-bit or x86 support claim |
| APK | GitHub release `v2026.9.1-azet4`, 24,887,478 bytes |
| APK SHA256 | `8bc1023b7d5bc011f78e8ab6bfce691dd89c6c0be3a4c91b51615da802a10248` |
| Source archive SHA256 | `38089f2c9146c93373198629d39a7d63d10f7299d163a1a3933f7ab4c358bf07` |
| Client license | GPL-3.0, `clients/LICENSE`; source archive attached to the matching release |
| Crypto SDK | sdk-internal `abc84458`, revert `8b9fa3e2`; GPL crates only; local Maven artifact |
| Server license | MIT, `server/LICENSE` |
| Existing script | `clients/build-android.sh` builds an APK with `assembleFdroidRelease`, not an AAB |

The exact published patched Android tree can be restored from the source archive into the existing `azet-pass-work/android` directory. Do not run the rebrand script again on this already patched tree. Write `localSdk=true` to its untracked `user.properties` to reuse the existing GPL SDK artifact in local Maven. Build an AAB using `cpuq ./gradlew :app:bundleFdroidRelease --max-workers=1 --no-parallel --no-daemon` with JDK 21 and the installed Android SDK. Signing must use the existing AZET upload identity, reading secrets at execution time from the vault, never command-line password values. AAB upload-key acceptance and Play App Signing enrollment are separate Console checks.

Native compatibility evidence: all five shared objects in APK4 have ELF LOAD alignments of 16384; the cached SDK library has the same alignment. `zipalign -c -P 16 -v 4` and `apksigner verify` passed for APK4. This proves static alignment/signature checks only; it does not prove a 16 KB runtime boot or Play's generated APK compatibility. After the AAB build, inspect its libraries and BundleConfig and run the Play pre-launch/device checks. [Android's 16 KB guide](https://developer.android.com/guide/practices/page-sizes).

## Permissions and sensitive APIs

Observed from the signed APK manifest, not inferred from the product category:

| Permission/API | Purpose / declaration action |
|---|---|
| INTERNET, ACCESS_NETWORK_STATE | Vault sync and connection status |
| USE_BIOMETRIC, USE_FINGERPRINT | Optional local biometric vault unlock; no biometric templates sent to AZET |
| CAMERA | Optional QR scan for authenticator setup; do not claim photo upload is mandatory |
| CredentialProviderService | Passkeys on supported Android versions |
| BIND_AUTOFILL_SERVICE | Android Autofill; enabled by the user in OS settings |
| BIND_ACCESSIBILITY_SERVICE | Optional fallback credential entry; declare use, `isAccessibilityTool=false` |
| ACCESS_LOCAL_NETWORK | Upstream local-network/self-hosted-server access screen; test the permission path |
| NFC | Inherited upstream hardware-token support; AZET server does not advertise hardware-key account 2FA |
| horizons.permission.HEADSET_CAMERA | Inherited upstream camera capability; not a required phone permission |
| READ_USER_DICTIONARY | Present in manifest; no caller found in app source scan. Lane 416 should remove if unused rather than invent a justification |
| POST_NOTIFICATIONS, WAKE_LOCK, RECEIVE_BOOT_COMPLETED, FOREGROUND_SERVICE | Framework/background operation declarations; verify runtime behavior before claiming notification delivery; F-Droid flavor excludes Firebase messaging/crashlytics |
| io.azet.pass.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION | Internal AndroidX receiver permission, not user data access |

Accessibility disclosure already exists at Settings > Autofill > Accessibility: `AutoFillScreen.kt` shows a two-button dialog before OS settings, with separate Accept and Decline actions. `accessibility_disclosure_text` explains login field reading and credential entry. Capture a real review video: show app/version → open Autofill → toggle Accessibility → read disclosure → Decline (stays off) → reopen and Accept → Android enable confirmation → fill one synthetic login → disable it. Record only synthetic credentials. Provide an accessible video URL in the Console declaration, and include the disclosure in the full store description. Source inspection is not a recorded walkthrough. [Google disclosure guidance](https://support.google.com/googleplay/android-developer/answer/11150561?hl=en).

## Data safety working answers

Scope: this F-Droid release plus the AZET sync service. Do not copy the upstream Play declaration, which includes a different telemetry build and server. Final answers require a release traffic capture and SDK audit.

| Data | Proposed response / evidence |
|---|---|
| Email and account ID | Collected, required for AZET sync; account management and app functionality |
| Name | Collected only if supplied; optional; account management |
| Password hint | Optional plaintext account field; classify under other personal information, not encrypted vault data |
| Device ID, type/name, last sign-in | Collected for authenticated devices/security; device identifiers and relevant app activity, required for sync |
| License/plan | Optional, only when entered; account management. Do not claim this build sells subscriptions |
| Website domains for icons | Optional when icons are enabled (default on); sent through AZET proxy; evaluate web-browsing data as ephemeral collection, even without stored logs |
| Encrypted vault/passkeys/attachments | E2EE contents qualify for the Play collection exclusion only while AZET/any intermediary cannot decrypt them. Metadata and plaintext account fields remain declared |
| Camera/biometrics/accessibility screen fields | Local processing, not collected solely because a permission exists; validate by traffic capture |
| Ads/analytics/crash reporting | No ads declared. Firebase dependencies are standard-only, not fdroid; verify final release dependency/traffic evidence before selecting no collection for all diagnostics |
| Breach check/email, password-prefix lookup | Only if exposed by the Android release; inspect invocation and third-party consent before finalizing sharing answers |
| Encryption in transit | AZET default endpoints are HTTPS. Self-hosted endpoint behavior must be checked before answering universally Yes |
| Sharing | Cloudflare processing on AZET's behalf can qualify for service-provider exclusion. Do not use this to omit independent optional third parties |

[Google Data safety definitions](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en) exclude unreadable E2EE content, but require ephemeral transmission to be answered in the form. Privacy policy: https://azet.io/privacy (Pass section observed live on 2026-10-16).

## Account deletion

In-app path: Settings > Account security > Delete account, then confirm using the master password. Source: Android `deleteaccountconfirmation` flow; server `POST /api/accounts/delete` and `DELETE /api/accounts` verify the password and remove Sends/storage, attachments, ciphers, folders and the account. The source is not proof of a completed live deletion in this session.

Current web help: https://pass.azet.io/help/#account, directing users to web-vault Settings > My account > Delete account. This is a candidate, not a certified Play deletion URL: add an obvious deletion request path (including a safe account-ownership check if the master password is lost), the data erased, any retained data and its retention period. Never request the master password or recovery code by email. A generic privacy-policy link alone is not sufficient. [Google deletion requirements](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en).

## Submission gates

- Publisher identity, Play account access and daily submission slot confirmed by lanes 449/446.
- Signed AAB produced, upload key verified, Play validation/pre-launch report reviewed.
- App icon, feature graphic and genuine phone screenshots attached; no generated UI evidence.
- Synthetic account: registration, sync, Autofill, biometric unlock, supported passkeys and deletion recorded.
- Accessibility declaration and review video attached; unused sensitive permissions resolved with lane 416.
- Data safety answers match release traffic and privacy policy; public deletion-request page verified.
- No unsupported Premium checkout claim or external purchase CTA; billing work is a separate gate.
- Korean publication copy reviewed by the responsible publishing lane before submission.

These gates are not checked merely because this document exists.
