#!/usr/bin/env python3
"""Builds the Mac App Store pictures (2880x1800) from window captures of the Mac app: a headline above the window on a
plain ground, rendered by headless Chromium. Captures are named <lang>-<n>-<name>.png (lang: ko, en).
usage: make-mac-store-images.py <chrome-headless-shell> <captures dir> <out dir>"""
import os, subprocess, sys, tempfile
chrome, raw, out = sys.argv[1], os.path.abspath(sys.argv[2]), os.path.abspath(sys.argv[3])
HEAD = {"ko": {"1-home": "가족 모두의 비밀번호를 한곳에서", "2-items": "금고와 카테고리로 정리합니다", "3-watchtower": "약한 비밀번호를 점수로 알려 줍니다",
               "4-family": "가족을 초대하고 금고를 대신 채워 주세요", "5-settings": "Touch ID로 열고, 알아서 잠급니다"},
        "en": {"1-home": "Your family's passwords in one place", "2-items": "Sorted by vault and by kind", "3-watchtower": "A score that shows weak passwords",
               "4-family": "Invite your family and fill their vaults", "5-settings": "Opens with Touch ID, locks by itself"}}
PAGE = """<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:1440px;height:900px;overflow:hidden;background:#f2f3f5;font-family:-apple-system,"Apple SD Gothic Neo",sans-serif}
h1{margin:0;padding:64px 80px 0;height:104px;font-size:46px;letter-spacing:-.02em;text-align:center;color:#0f1115;word-break:keep-all}
img{display:block;margin:0 auto;width:1040px;border-radius:14px;box-shadow:0 24px 70px rgba(15,17,21,.2)}
</style><h1>%s</h1><img src="file://%s">"""
w = tempfile.mkdtemp(prefix="azp-mac-")
for lang, heads in HEAD.items():
    os.makedirs(os.path.join(out, lang), exist_ok=True)
    for n, (name, head) in enumerate(heads.items(), 1):
        page = os.path.join(w, "p.html"); open(page, "w").write(PAGE % (head, os.path.join(raw, f"{lang}-{name}.png")))
        png = os.path.join(out, lang, f"{n}-{name.split('-', 1)[1]}.png")
        subprocess.run([chrome, "--headless", "--use-mock-keychain", "--password-store=basic", "--allow-file-access-from-files", "--hide-scrollbars",
                        "--window-size=1440,900", "--force-device-scale-factor=2", f"--screenshot={png}", "file://" + page], capture_output=True, timeout=90)
        print(lang, n, os.path.exists(png))
