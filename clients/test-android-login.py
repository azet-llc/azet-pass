#!/usr/bin/env python3
"""Installs an AZET Pass Android APK on an emulator, signs in with the test account (key vault) and prints what each
screen says. The password reaches the device through adb's stdin, never a command line or the output.
Usage: test-android-login.py <adb serial> <apk> [package]"""
import re, subprocess, sys, time
serial, apk = sys.argv[1], sys.argv[2]
pkg = sys.argv[3] if len(sys.argv) > 3 else "io.azet.pass"
vault = lambda n: subprocess.run(["tkt", "get", n], capture_output=True, text=True).stdout.strip()
email, password = vault("AZET_PASS_AGENT_EMAIL"), vault("AZET_PASS_AGENT_PASSWORD")
adb = lambda *a: subprocess.run(["adb", "-s", serial, *a], capture_output=True, text=True).stdout
sh = lambda line: subprocess.run(["adb", "-s", serial, "shell"], input=line + "\n", capture_output=True, text=True).stdout


def screen():
    sh("uiautomator dump /sdcard/u.xml >/dev/null")
    return adb("shell", "cat", "/sdcard/u.xml")


def texts(xml):
    return [t.replace(password, "(hidden)") for t in re.findall(r'(?:text|content-desc)="([^"]+)"', xml)]


def tap(xml, *words):
    for w in words:
        m = re.search(r'(?:text|content-desc)="%s"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"' % re.escape(w), xml)  # Compose buttons carry their label as content-desc
        if m:
            x1, y1, x2, y2 = map(int, m.groups()); sh(f"input tap {(x1 + x2) // 2} {(y1 + y2) // 2}"); return w
    return None


def step(name, wait=4):
    time.sleep(wait); xml = screen(); print(f"--- {name}:", " | ".join(texts(xml))[:420]); return xml


print(adb("install", "-r", apk).strip().splitlines()[-1])
adb("shell", "am", "start", "-n", adb("shell", "cmd", "package", "resolve-activity", "--brief", pkg).strip().splitlines()[-1])
xml = step("first", 12)
tap(xml, "Log in", "로그인")
xml = step("login")
field = re.search(r'class="android.widget.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
if field:
    x1, y1, x2, y2 = map(int, field.groups()); sh(f"input tap {(x1 + x2) // 2} {(y1 + y2) // 2}")
sh(f"input text '{email}'"); tap(screen(), "Continue", "계속")
xml = step("master password", 8)
if "Master password" not in xml and "마스터 비밀번호" not in xml:
    sys.exit("stopped: not on the master password screen, nothing typed")
field = re.search(r'class="android.widget.EditText"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', xml)
if field:
    x1, y1, x2, y2 = map(int, field.groups()); sh(f"input tap {(x1 + x2) // 2} {(y1 + y2) // 2}")
sh("input text '%s'" % password.replace("'", "'\\''")); tap(screen(), "Log in with master password", "마스터 비밀번호로 로그인")
xml = step("after login", 15)
for _ in range(3):  # autofill / biometrics offers
    if not tap(xml, "Skip", "Not now", "Maybe later", "Ask me later", "Set up later", "Confirm", "No thanks"): break
    xml = step("after offer", 5)
all_text = " ".join(texts(screen()))
print("items seen:", [n for n in ("demo-login", "fill-test.azet.example") if n in all_text])
print("old name on screen:", len(re.findall("bitwarden", all_text, re.I)))
print("running:", bool(sh(f"pidof {pkg}").strip()))
