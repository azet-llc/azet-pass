#!/usr/bin/env python3
"""Builds the Play listing's phone pictures (1080x1920) from raw screen captures: a headline above the screen on a plain
ground, rendered by headless Chromium. Raw captures are named <lang>-<n>-<name>.png (lang: ko, en).
usage: make-play-images.py <chrome-headless-shell> <raw dir>   (writes fastlane/metadata/android/<locale>/images/phoneScreenshots/<n>.png)"""
import os, subprocess, sys, tempfile
chrome, raw = sys.argv[1], os.path.abspath(sys.argv[2])
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
HEAD = {"ko": {"1-home": "비밀번호를 한 금고에", "3-logins": "앱과 사이트 로그인을 자동으로 채웁니다", "4-item": "아이디·비밀번호·인증 코드를 한곳에",
               "5-generator": "강한 비밀번호를 바로 만듭니다", "6-check": "약한 비밀번호를 찾아 줍니다", "2-items": "카드·주소·메모도 함께"},
        "en": {"1-home": "Every password in one vault", "3-logins": "Fills sign-ins in apps and sites", "4-item": "User name, password and code together",
               "5-generator": "Strong passwords in a tap", "6-check": "Finds weak passwords", "2-items": "Cards, addresses and notes too"}}
ORDER = ["1-home", "3-logins", "4-item", "6-check", "5-generator", "2-items"]
LOCALE = {"ko": ["ko-KR"], "en": ["en-US", "ja-JP"]}  # the Japanese listing shows the English pictures
PAGE = """<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:1080px;height:1920px;overflow:hidden;background:#f2f3f5;font-family:-apple-system,"Apple SD Gothic Neo",sans-serif}
h1{margin:0;padding:120px 80px 0;height:250px;font-size:68px;line-height:1.16;letter-spacing:-.02em;text-align:center;color:#0f1115;word-break:keep-all}
img{display:block;margin:0 auto;width:800px;border-radius:56px 56px 0 0;box-shadow:0 30px 80px rgba(15,17,21,.16)}
</style><h1>%s</h1><img src="file://%s">"""
w = tempfile.mkdtemp(prefix="azp-play-")
for lang, heads in HEAD.items():
    for n, name in enumerate(ORDER, 1):
        src = os.path.join(raw, f"{lang}-{name}.png")
        page = os.path.join(w, "p.html"); open(page, "w").write(PAGE % (heads[name], src))
        for loc in LOCALE[lang]:
            out = os.path.join(root, "fastlane/metadata/android", loc, "images/phoneScreenshots"); os.makedirs(out, exist_ok=True)
            png = os.path.join(out, f"{n}.png")
            subprocess.run([chrome, "--headless", "--use-mock-keychain", "--password-store=basic", "--allow-file-access-from-files", "--hide-scrollbars",
                            "--window-size=1080,1920", f"--screenshot={png}", "file://" + page], capture_output=True, timeout=90)
            print(loc, n, name, os.path.exists(png))
