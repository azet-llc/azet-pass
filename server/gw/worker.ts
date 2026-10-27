// 공개 프런트(게이트웨이) — 오너 09-22 프런트/백엔드 분리 표준(~/.claude/rules/cloudflare-front-back-split.md).
// 데이터 바인딩·외부 키 없음. 웹 금고(../public/web-vault)는 Worker 를 거치지 않고 나가고, /api·/identity·/notifications·/icons 만 쿠키를 지우고(서버는 쿠키를 쓰지 않는다 — 토큰은 Authorization)
// 내부 키 헤더를 붙여 서비스 바인딩(BACKEND = 비공개 azet-pass)으로 그대로 넘긴다. 백엔드가 정한 헤더는 덮지 않고 HSTS·nosniff 만 채운다. 알림 웹소켓(101)은 그대로 돌려준다.
interface Env {
  BACKEND: Fetcher;
  INTERNAL_KEY: string; // 백엔드와 같은 값 — wrangler secret (볼트 AZET_PASS_INTERNAL_KEY)
}

// io.azet.pass signing certificate (vault AZET_PASS_ANDROID_KEYSTORE_B64, alias azet-pass)
const ASSET_LINKS = [{ relation: ["delegate_permission/common.handle_all_urls"], target: { namespace: "android_app", package_name: "io.azet.pass",
  sha256_cert_fingerprints: ["7C:14:57:6D:08:E3:C3:5B:D3:96:94:1E:50:51:24:E5:C1:4B:78:93:DF:1C:8F:D1:E6:DF:9D:9D:F2:8E:9F:2B"] } }];

// iOS universal links: family invites (/invite#…) and the sign-up mail link open AZET Pass for iPhone when installed.
const AASA = { applinks: { details: [{ appIDs: ["95P4H2RG24.io.azet.pass"], components: [{ "/": "/invite*" }, { "/": "/redirect-connector.html*" }] }] },
  webcredentials: { apps: ["95P4H2RG24.io.azet.pass"] } };

// Family invite landing page: the token stays in the #fragment (never sent to a server); the page hands it to the app.
const INVITE = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>AZET Pass</title><style>body{margin:0;font:17px/1.5 -apple-system,system-ui,sans-serif;background:#f4f7f6;color:#0d1f1a}
main{max-width:420px;margin:0 auto;padding:48px 20px;text-align:center}h1{font-size:26px;margin:16px 0 8px}p{color:#4a5b56}
a.b{display:block;margin:14px 0;padding:15px;border-radius:14px;background:#0d7d66;color:#fff;text-decoration:none;font-weight:600}
a.s{background:#fff;color:#0d7d66;border:1px solid #cfe3dd}.logo{width:76px;height:76px;border-radius:18px;background:linear-gradient(135deg,#14a386,#0b5e4e);margin:0 auto}</style></head>
<body><main><div class="logo"></div><h1 id="t">Your family invited you</h1><p id="d">Open this page on your phone. Install AZET Pass, then tap Open in the app.</p>
<a class="b" id="open" href="#">Open in AZET Pass</a><a class="b s" id="get" href="https://apps.apple.com/app/id6823484052">Get AZET Pass for iPhone</a>
<a class="b s" id="and" href="https://play.google.com/store/apps/details?id=io.azet.pass">Get AZET Pass for Android</a></main>
<script>var $=function(i){return document.getElementById(i)};if((navigator.language||'').indexOf('ko')==0){$('t').textContent='가족이 AZET Pass에 초대했어요';$('d').textContent='휴대폰에서 이 페이지를 여세요. AZET Pass를 설치한 뒤 「앱에서 열기」를 누르면 돼요.';$('open').textContent='앱에서 열기';$('get').textContent='iPhone용 AZET Pass 받기';$('and').textContent='Android용 AZET Pass 받기'}
$('open').href='azetpass://invite'+location.hash;</script></body></html>`;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const path = new URL(req.url).pathname;
    // Android App Links: lets AZET Pass for Android open the sign-up mail link (/redirect-connector.html#finish-signup…)
    if (path === "/.well-known/assetlinks.json") return Response.json(ASSET_LINKS);
    if (path === "/.well-known/apple-app-site-association") return Response.json(AASA);
    if (path === "/invite" || path === "/invite/") return new Response(INVITE, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer" } });
    if (!env.INTERNAL_KEY) return new Response("unavailable", { status: 503 });
    const h = new Headers(req.headers);
    h.delete("Cookie");
    h.set("X-Azet-Internal", env.INTERNAL_KEY);
    const res = await env.BACKEND.fetch(new Request(req, { headers: h }));
    if (res.status === 101 || res.webSocket) return res;
    const out = new Response(res.body, res);
    const set = (k: string, v: string) => out.headers.has(k) || out.headers.set(k, v);
    set("Strict-Transport-Security", "max-age=31536000; includeSubDomains");
    set("X-Content-Type-Options", "nosniff");
    return out;
  },
} satisfies ExportedHandler<Env>;
