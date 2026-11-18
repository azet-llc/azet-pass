// AZET Pass desktop, on top of rebrand.mjs: (1) one button that uploads every password saved in every browser and
// profile on this computer, skipping what the vault already holds; (2) updates that arrive by themselves, the way
// AZET Desktop's do: checked every 4 hours, downloaded in the background, installed when the computer has been idle
// for 5 minutes (or when the app quits), with no question in between.
// usage: node rebrand-desktop.mjs <clients dir>
import fs from 'node:fs'
import path from 'node:path'

const root = path.resolve(process.argv[2] || '')
const version = process.argv[3] // e.g. 2026.10.401 (pins.env DESKTOP_VERSION); left as upstream when not given
const p = (f) => path.join(root, f)
const swap = (file, pairs) => {
  let s = fs.readFileSync(p(file), 'utf8')
  for (const [a, b] of pairs) {
    if (!s.includes(a)) throw new Error(`rebrand-desktop: ${a.slice(0, 60)} not found in ${file} (upstream moved?)`)
    s = s.replace(a, b)
  }
  fs.writeFileSync(p(file), s)
}

// ---- (1) import everything ----
const comp = 'apps/desktop/src/app/tools/import/import-desktop.component.ts'
swap(comp, [
  ['import { Component, inject } from "@angular/core";', 'import { Component, inject } from "@angular/core";\nimport { firstValueFrom } from "rxjs";'],
  ['import { I18nService } from "@bitwarden/common/platform/abstractions/i18n.service";',
    'import { AccountService } from "@bitwarden/common/auth/abstractions/account.service";\nimport { getUserId } from "@bitwarden/common/auth/services/account.service";\nimport { I18nService } from "@bitwarden/common/platform/abstractions/i18n.service";\nimport { CipherService } from "@bitwarden/common/vault/abstractions/cipher.service";'],
  ['  DialogModule,\n} from "@bitwarden/components";', '  DialogModule,\n  ToastService,\n} from "@bitwarden/components";'],
  ['import { ImportMetadataServiceAbstraction } from "@bitwarden/importer-core";',
    'import { ImportMetadataServiceAbstraction, ImportServiceAbstraction } from "@bitwarden/importer-core";'],
  ['  protected readonly onImportFromBrowser = this._onImportFromBrowser.bind(this);',
    `  protected readonly onImportFromBrowser = this._onImportFromBrowser.bind(this);
  protected everything = false;
  private readonly importService = inject(ImportServiceAbstraction);
  private readonly cipherService = inject(CipherService);
  private readonly accountService = inject(AccountService);
  private readonly toastService = inject(ToastService);

  // AZET: every password saved in every browser and profile on this computer, in one go. What the vault already
  // holds (same site, username and password) is skipped, so pressing it again adds only what is new.
  protected readonly importEverything = async (): Promise<void> => {
    const names: Record<string, string> = {
      arccsv: "Arc",
      bravecsv: "Brave",
      chromecsv: "Chrome",
      chromiumcsv: "Chromium",
      edgecsv: "Microsoft Edge",
      operacsv: "Opera",
      vivaldicsv: "Vivaldi",
    };
    this.everything = true;
    this.loading = true;
    try {
      const meta = await ipc.tools.chromiumImporter.getMetadata();
      const browsers = Object.keys(meta)
        .filter((id) => meta[id].loaders.includes("chromium") && names[id] != null)
        .map((id) => names[id]);
      const found: { url: string; username: string; password: string; note: string }[] = [];
      const read: string[] = [];
      for (const browser of browsers) {
        let profiles: chromium_importer.ProfileInfo[] = [];
        try {
          profiles = await this._onLoadProfilesFromBrowser(browser);
        } catch {
          continue; // not allowed or not readable: the other browsers still count
        }
        for (const profile of profiles) {
          try {
            const logins = await ipc.tools.chromiumImporter.importLogins(browser, profile.id);
            found.push(...logins.filter((l) => l.login != null).map((l) => l.login));
            read.push(browser);
          } catch {
            // one profile that cannot be read does not stop the others
          }
        }
      }
      const key = (url: string, username: string, password: string) => {
        let host = url;
        try {
          host = new URL(url).hostname;
        } catch {
          // kept as written
        }
        return [host, username ?? "", password ?? ""].join("\\u0000");
      };
      const userId = await firstValueFrom(this.accountService.activeAccount$.pipe(getUserId));
      const have = new Set(
        (await this.cipherService.getAllDecrypted(userId))
          .filter((c) => c.login != null && c.deletedDate == null)
          .flatMap((c) =>
            (c.login.uris?.length ? c.login.uris : [{ uri: "" }]).map((u) =>
              key(u.uri ?? "", c.login.username ?? "", c.login.password ?? ""),
            ),
          ),
      );
      const fresh = new Map<string, (typeof found)[number]>();
      for (const login of found) {
        const k = key(login.url, login.username, login.password);
        if (!have.has(k)) {
          fresh.set(k, login);
        }
      }
      if (fresh.size === 0) {
        this.toastService.showToast({
          variant: "info",
          title: null,
          message: this.i18nService.t(
            read.length ? "azetImportEverythingNothingNew" : "azetImportEverythingNoBrowser",
          ),
        });
        return;
      }
      const rows = [...fresh.values()].map((l) => {
        let name = l.url;
        try {
          name = new URL(l.url).hostname;
        } catch {
          // kept as written
        }
        return { name, url: l.url, username: l.username, password: l.password, note: l.note ?? "" };
      });
      const csv = papa.unparse(rows);
      const importer = this.importService.getImporter("chromecsv", async () => "", undefined);
      await this.importService.import(importer, csv);
      this.toastService.showToast({
        variant: "success",
        title: null,
        message: this.i18nService.t(
          "azetImportEverythingDone",
          String(fresh.size),
          [...new Set(read)].join(", "),
        ),
      });
      await this.dialogRef.close();
    } catch (error) {
      this.toastService.showToast({
        variant: "error",
        title: this.i18nService.t("errorOccurred"),
        message: error instanceof Error ? error.message : String(error),
      });
    } finally {
      this.everything = false;
      this.loading = false;
    }
  };`],
  ['import { CommonModule } from "@angular/common";', 'import { CommonModule } from "@angular/common";\nimport * as papa from "papaparse";'],
])
swap('apps/desktop/src/app/tools/import/import-desktop.component.html', [
  ['  <ng-container bitDialogContent>\n',
    `  <ng-container bitDialogContent>
    <div class="tw-mb-4 tw-rounded-xl tw-border tw-border-solid tw-border-secondary-300 tw-p-4">
      <p class="tw-mb-1 tw-font-semibold">{{ "azetImportEverythingTitle" | i18n }}</p>
      <p class="tw-mb-3 tw-text-sm tw-text-muted">{{ "azetImportEverythingDesc" | i18n }}</p>
      <button type="button" bitButton buttonType="primary" [loading]="everything" [disabled]="loading" (click)="importEverything()">
        {{ "azetImportEverythingButton" | i18n }}
      </button>
    </div>
`],
])

// the words, in every language table of the desktop app (Korean and English written; the rest falls back to English)
const WORDS = {
  en: {
    azetImportEverythingTitle: 'Upload every saved password on this computer',
    azetImportEverythingDesc: 'Reads the passwords saved in every browser and profile here (Chrome, Edge, Brave, Arc, Opera, Vivaldi) and adds the ones your vault does not have yet. It is encrypted on this computer before it is sent.',
    azetImportEverythingButton: 'Upload all',
    azetImportEverythingDone: { message: 'Added $COUNT$ logins from $SOURCES$.', placeholders: { count: { content: '$1' }, sources: { content: '$2' } } },
    azetImportEverythingNothingNew: 'Nothing new: your vault already has every saved password on this computer.',
    azetImportEverythingNoBrowser: 'No browser on this computer could be read. Allow access when asked, or import a file below.',
  },
  ko: {
    azetImportEverythingTitle: '이 컴퓨터에 저장된 비밀번호 모두 올리기',
    azetImportEverythingDesc: '이 컴퓨터의 모든 브라우저·프로필(Chrome, Edge, Brave, Arc, Opera, Vivaldi)에 저장된 비밀번호를 읽어, 금고에 아직 없는 것만 더합니다. 보내기 전에 이 컴퓨터에서 암호화됩니다.',
    azetImportEverythingButton: '모두 올리기',
    azetImportEverythingDone: { message: '$SOURCES$에서 로그인 $COUNT$개를 더했어요.', placeholders: { count: { content: '$1' }, sources: { content: '$2' } } },
    azetImportEverythingNothingNew: '새로 더할 것이 없어요. 이 컴퓨터에 저장된 비밀번호는 이미 모두 금고에 있어요.',
    azetImportEverythingNoBrowser: '읽을 수 있는 브라우저가 없어요. 접근을 물으면 허용하거나, 아래에서 파일로 가져오세요.',
  },
}
const dir = p('apps/desktop/src/locales')
for (const lang of fs.readdirSync(dir)) {
  const f = path.join(dir, lang, 'messages.json')
  if (!fs.existsSync(f)) continue
  const j = JSON.parse(fs.readFileSync(f, 'utf8'))
  for (const [k, v] of Object.entries(WORDS[lang === 'ko' ? 'ko' : 'en'])) j[k] = typeof v === 'string' ? { message: v } : v
  fs.writeFileSync(f, JSON.stringify(j, null, 2) + '\n')
}

// ---- (2) updates that arrive by themselves ----
const up = 'apps/desktop/src/main/updater.main.ts'
swap(up, [
  ['const UpdaterCheckInterval = 12 * 60 * 60 * 1000; // 12 hours', 'const UpdaterCheckInterval = 4 * 60 * 60 * 1000; // AZET: 4 hours, as AZET Desktop\nconst InstallWhenIdleSeconds = 5 * 60; // AZET: installed once the computer has been idle this long'],
  ['import { dialog, IpcMainEvent, ipcMain, Notification } from "electron";', 'import { dialog, IpcMainEvent, ipcMain, Notification, powerMonitor } from "electron";'],
  [`      this.updateDownloaded = info;
      await this.promptRestartUpdate(info, this.doingUpdateCheckWithFeedback);`,
    `      this.updateDownloaded = info;
      if (this.doingUpdateCheckWithFeedback) {
        await this.promptRestartUpdate(info, true);
        return;
      }
      // AZET: no question. It installs when the app quits, or after five idle minutes (the vault locks on
      // restart and opens again with Touch ID or the master password).
      const idle = global.setInterval(() => {
        if (powerMonitor.getSystemIdleTime() >= InstallWhenIdleSeconds) {
          global.clearInterval(idle);
          autoUpdater.quitAndInstall(true, true);
        }
      }, 60 * 1000);`],
  ['"https://github.com/bitwarden/clients/releases"', '"https://azet.io/pass"'],
])
if (version) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) throw new Error(`rebrand-desktop: bad version ${version}`)
  for (const f of ['apps/desktop/package.json', 'apps/desktop/src/package.json'])
    swap(f, [[/"version": "[^"]+"/.exec(fs.readFileSync(p(f), 'utf8'))[0], `"version": "${version}"`]])
}
console.log('rebrand-desktop: import-everything + silent updates')
