# Chrome Web Store / Microsoft Edge Add-ons listing — AZET Pass Password Manager 2026.9.3.5

Packages (from `build-extension.sh`, same run as `azet-pass-firefox-2026.9.3.5.zip` for AMO): `azet-pass-chrome-2026.9.3.5.zip` (Chrome Web Store),
`azet-pass-edge-2026.9.3.5.zip` (Edge Add-ons). Copies sit next to this file; zips are not in git.
The Firefox listing is on AMO (`azet-pass-password-manager`, id 3087714); its text is the source of the English description below.

- Name: AZET Pass Password Manager (KO: AZET Pass 비밀번호 관리자) — from `_locales/*/messages.json` `extName`
- Category: Chrome "Tools" (Workflow & Planning > Tools); Edge "Productivity"
- Homepage: https://azet.io/products/pass — Support: hello@azet.io — Privacy policy: https://azet.io/privacy#pass (KO: https://azet.io/privacy-ko#pass)
- Developer: AZET LLC
- Languages: English, Korean
- Icon: `images/icon128.png` in the package

## Short description (132 characters max)
EN: Password manager with free authenticator (TOTP) codes. Your vault is encrypted on your device and synced with pass.azet.io.

KO: 인증(TOTP) 코드가 무료인 비밀번호 관리자. 보관함은 기기에서 암호화된 뒤 pass.azet.io와 동기화됩니다.

## Description (EN)
AZET Pass keeps your logins, cards, identities, notes and passkeys in one vault that is encrypted on your device before it is synced. The server at pass.azet.io never receives your master password or your encryption key.

- Save and fill logins, cards and identities on the sites you use; save new logins when you sign in.
- Passkeys: create and use passkeys stored in your vault.
- Authenticator (TOTP) codes are shown, filled and copied on the free plan.
- Password and passphrase generator.
- Send: share text through an encrypted link.
- The same vault in the desktop app, the Android app and the web vault at pass.azet.io.

Free plan: unlimited passwords and devices, autofill, password generator, Send, authenticator codes. Premium (attachments and more) is added to your account with an AZET license key.

AZET Pass is the open-source Bitwarden browser extension (GPL-3.0), built from source with our name, icon and server address. AZET Pass is not made or endorsed by Bitwarden, Inc. Source code and build scripts: https://github.com/neulketing/azet-pass

## 설명 (KO)
AZET Pass 는 로그인, 카드, 신원 정보, 메모, 패스키를 보관함 하나에 담고, 동기화하기 전에 기기에서 암호화합니다. pass.azet.io 서버는 마스터 비밀번호와 암호화 키를 받지 않습니다.

- 쓰는 사이트에서 로그인·카드·신원 정보를 저장하고 채웁니다. 새로 로그인하면 저장할지 묻습니다.
- 패스키: 보관함에 패스키를 만들고 씁니다.
- 인증(TOTP) 코드를 무료 플랜에서 보여 주고, 채우고, 복사합니다.
- 비밀번호·패스프레이즈 생성기.
- Send: 암호화된 링크로 텍스트를 공유합니다.
- 데스크톱 앱, Android 앱, 웹 보관함(pass.azet.io)에서 같은 보관함을 씁니다.

무료 플랜: 비밀번호와 기기 수 제한 없음, 자동 채우기, 비밀번호 생성기, Send, 인증 코드. 프리미엄(첨부 파일 등)은 AZET 라이선스 키로 계정에 추가합니다.

AZET Pass 는 오픈소스 Bitwarden 브라우저 확장(GPL-3.0)을 우리 이름·아이콘·서버 주소로 소스에서 빌드한 것입니다. Bitwarden, Inc. 가 만들거나 보증한 제품이 아닙니다. 소스 코드와 빌드 스크립트: https://github.com/neulketing/azet-pass

## Single purpose (Chrome Web Store)
AZET Pass is a password manager: it stores your logins, passkeys, cards and identities in an encrypted vault and fills them into the websites you use.

## Permission justifications
Read from `manifest.json` of both 2026.9.3.5 packages: 16 permissions, 2 optional permissions, 2 host permissions (the Chrome and Edge lists are identical).

Permissions (16)
1. `activeTab`: fill the login you pick from the popup, shortcut or context menu into the tab you are on.
2. `alarms`: lock the vault after the timeout you set, clear a copied password from the clipboard after your chosen delay, and sync the vault on a schedule (the service worker cannot keep timers).
3. `clipboardRead`: before clearing the clipboard, check that it still holds the value AZET Pass copied, so nothing else you copied is erased.
4. `clipboardWrite`: copy a username, password or authenticator code when you press Copy, and copy the authenticator code after autofill if you turned that on.
5. `contextMenus`: the right-click menu to fill a login, card or identity, copy a password or code, or generate a password.
6. `idle`: lock the vault when the computer is idle or locked, if you chose that vault timeout.
7. `offscreen`: a hidden document for clipboard copy and clear, which a Manifest V3 service worker cannot do itself.
8. `scripting`: insert the autofill and passkey scripts into the page being filled.
9. `sidePanel`: reserved by the upstream extension for opening the vault in the browser's side panel; the manifest's default side-panel page is an empty placeholder (`sidepanel-disabled.html`), and a panel opens only if you choose that view.
10. `storage`: keep the encrypted vault copy, account settings and session state on the device.
11. `tabs`: read the address of the current tab to list the logins that match it, and open the vault, a login's website or a pop-out window in a tab.
12. `unlimitedStorage`: a large vault can exceed the default local storage quota.
13. `webNavigation`: notice page and frame loads so the inline autofill menu and the save-login prompt appear on the right frame, and re-inject after single-page navigations.
14. `webRequest`: see form submissions and their responses to offer to save a new or changed login, and to track which frames are login forms.
15. `webRequestAuthProvider`: answer HTTP Basic/Digest authentication prompts with the matching saved login.
16. `notifications`: tell you when an action needs you, such as a sign-in request from another device waiting for approval.

Optional permissions (2), asked only when you turn the feature on
17. `nativeMessaging`: talk to the AZET Pass desktop app for unlock with biometrics.
18. `privacy`: turn off the browser's own password saving and autofill when you make AZET Pass the default password manager.

Host permissions (2)
19. `https://*/*`: a password manager has to work on any site you have a login for: detect login, card and identity fields, show the inline menu, fill them, offer to save new logins, and provide passkeys. It also reaches the sync server (pass.azet.io, or the server address you enter).
20. `http://*/*`: the same for sites and local devices (routers, intranet pages) that are still served over http.

Content scripts run on `*://*/*` and `file:///*` (`.xml` excluded) for the same field detection and fill.
Remote code: none. All code is in the package (`script-src 'self' 'wasm-unsafe-eval'`; the WebAssembly is the bundled cryptography library).

## Data use (Chrome privacy tab / Edge privacy questions)
Same facts as https://azet.io/privacy#pass.
- Personally identifiable information: yes. Account email address and the name you give, if any.
- Authentication information: yes. The vault holds your saved passwords, passkeys and authenticator secrets. They are encrypted on your device before upload; the server never receives the master password or the encryption key, only a hash used to sign you in.
- Financial and payment information: yes, only if you save cards in the vault (encrypted on the device like everything else). AZET Pass takes no payments.
- Web history: yes, limited. The website addresses saved in your logins are part of the encrypted vault; while "Show website icons" is on (the default), the extension asks pass.azet.io for each saved website's icon, so the server sees those domain names. It does not send the pages you visit.
- Website content: read on the device to find and fill form fields; not sent anywhere.
- Health information, personal communications, location, user activity (clicks, keystrokes): no.
- Sent with every request to the server: client name, version and device type; the server stores the devices you sign in on.
- Certifications: data is not sold or transferred to third parties outside the approved use cases; not used for purposes unrelated to the single purpose; not used for creditworthiness or lending.
- Firefox manifest for comparison: required `authenticationInfo`, `personallyIdentifyingInfo`, `financialAndPaymentInfo`, `browsingActivity`; optional `technicalAndInteraction`.

## Notes for the reviewer (test instructions field)
Create a free account in the extension (Create account) or at https://pass.azet.io; no payment or license key is needed for anything in the description except Premium.

## Screenshots to capture (1280x800, not made yet: needs a browser)
1. Popup, Vault tab on a site with a matching login (the "Autofill suggestions" list).
2. A login form with the inline autofill menu open under the username field.
3. A login item open in the popup showing the authenticator (TOTP) code and its countdown.
4. Password generator tab.
5. Save-login notification bar after signing in to a site.
Small promo tile 440x280 (Chrome) and 300x300 logo (Edge): from `clients/brand`.
