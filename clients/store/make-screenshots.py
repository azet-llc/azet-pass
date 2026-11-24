#!/usr/bin/env python3
"""Builds the extension's store pictures (1280x800, en and ko) from the real popup files with sample data: the popup
runs in a frame with a stand-in for the browser API, beside a headline, and headless Chromium takes the picture.
usage: make-screenshots.py <chrome-headless-shell>   (writes store/screenshots/pass-<n>-<lang>-1280x800.png)"""
import json, os, shutil, subprocess, sys, tempfile
here = os.path.dirname(os.path.abspath(__file__)); src = os.path.join(here, "../extension/src"); out = os.path.join(here, "screenshots")
chrome = sys.argv[1]
ITEMS = {"en": [["GitHub", "kim.azet", "login", 1], ["Amazon", "kim@azet.example", "login", 0], ["Google", "kim@azet.example", "login", 1], ["Visa", "**** 1111", "card", 0],
                ["Home address", "Kim Azet", "identity", 0], ["Cloudflare", "ops@azet.example", "login", 1], ["Netflix", "kim@azet.example", "login", 0]],
         "ko": [["네이버", "kim.azet", "login", 1], ["쿠팡", "kim@azet.example", "login", 0], ["GitHub", "azet-dev", "login", 1], ["국민카드", "**** 1111", "card", 0],
                ["집 주소", "김에이젯", "identity", 0], ["Cloudflare", "ops@azet.example", "login", 1], ["카카오", "kim@azet.example", "login", 0]]}
HOST = {"en": "github.com", "ko": "nid.naver.com"}
# (popup query, headline, line under it)
SHOTS = {"en": [("phase=unlocked", "The sign-in for this page, one click away", "AZET Pass shows the logins saved for the site you are on and fills them in."),
                ("phase=unlocked&tab=all", "Passwords, cards, addresses and codes in one vault", "Encrypted on your device before it syncs. Free authenticator codes."),
                ("phase=signedOut", "Start with your email", "One step at a time: email, then your account password.")],
         "ko": [("phase=unlocked", "지금 페이지의 로그인을 한 번에", "보고 있는 사이트에 저장된 로그인을 보여 주고 바로 채워 줍니다."),
                ("phase=unlocked&tab=all", "비밀번호·카드·주소·인증 코드를 한 금고에", "기기에서 암호화한 뒤 동기화합니다. 인증 코드는 무료입니다."),
                ("phase=signedOut", "이메일로 시작하세요", "한 번에 한 단계씩: 이메일, 그다음 계정 비밀번호.")]}
STUB = """<script>
const Q=new URLSearchParams(location.search), phase=Q.get("phase")||"unlocked";
const x=new XMLHttpRequest();x.open("GET","messages.json",false);x.send();const M=JSON.parse(x.responseText);
const items=%s.map((a,i)=>({id:String(i),name:a[0],sub:a[1],kind:a[2],totp:!!a[3]}));
window.chrome={i18n:{getMessage:(k,a)=>{let m=M[k]?.message||"";(a||[]).forEach((v,i)=>m=m.replaceAll("$"+(i+1),v));return m}},
 tabs:{query:async()=>[{id:1,url:"https://%s/login"}],create(){}},
 runtime:{getURL:(u)=>u,sendMessage:async(m)=>({ok:true,result:({state:{phase,email:"kim@azet.example",items:items.length},list:{host:"%s",here:items.slice(0,1),all:items},pinState:{on:false},desktopState:{helper:false,on:false,asked:true},generate:"q7#Lm2vX9!paR4tZc8Wd",maskedEmail:"kim+x7k@azet.example"})[m.type]})}};
addEventListener("load",()=>setTimeout(()=>{const b=document.querySelector(`[data-tab="${Q.get("tab")}"]`);if(b)b.click()},300));
</script><style>section,.step{animation:none!important}</style>"""
PAGE = """<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;height:100%%}body{display:flex;align-items:center;gap:72px;padding:0 96px;box-sizing:border-box;background:#f2f3f5;font-family:-apple-system,"Apple SD Gothic Neo",sans-serif;color:#0f1115}
h1{font-size:44px;line-height:1.14;letter-spacing:-.02em;margin:22px 0 18px;word-break:keep-all}p{font-size:22px;line-height:1.5;color:#5c6370;margin:0;word-break:keep-all}
.t{flex:1}.t img{width:64px;height:64px;border-radius:16px}iframe{width:420px;height:660px;border:0;border-radius:28px;background:#fff;box-shadow:0 24px 60px rgba(15,17,21,.14)}
</style><div class="t"><img src="images/icon-128.png"><h1>%s</h1><p>%s</p></div><iframe src="popup.html?%s"></iframe>"""
w = tempfile.mkdtemp(prefix="azp-store-")
for f in ("popup.css", "popup.js"): shutil.copy(os.path.join(src, f), w)
shutil.copytree(os.path.join(src, "images"), os.path.join(w, "images"))
html = open(os.path.join(src, "popup.html")).read()
os.makedirs(out, exist_ok=True)
for lang in ("en", "ko"):
    shutil.copy(os.path.join(src, "_locales", lang, "messages.json"), os.path.join(w, "messages.json"))
    open(os.path.join(w, "popup.html"), "w").write(html.replace("<head>", "<head>" + STUB % (json.dumps(ITEMS[lang], ensure_ascii=False), HOST[lang], HOST[lang]), 1))
    for n, (q, h, p) in enumerate(SHOTS[lang], 1):
        open(os.path.join(w, "page.html"), "w").write(PAGE % (h, p, q))
        png = os.path.join(out, f"pass-{n}-{lang}-1280x800.png")
        subprocess.run([chrome, "--headless", "--use-mock-keychain", "--password-store=basic", "--allow-file-access-from-files", "--hide-scrollbars",
                        "--window-size=1280,800", "--virtual-time-budget=8000", f"--screenshot={png}", "file://" + os.path.join(w, "page.html")],
                       capture_output=True, timeout=90)
        print(os.path.basename(png), os.path.exists(png))
shutil.rmtree(w)
