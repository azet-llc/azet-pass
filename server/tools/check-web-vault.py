#!/usr/bin/env python3
"""check-web-vault.py <web-vault dir>: refuses (exit 1) a gateway deploy whose web vault folder is missing, empty, has no
index.html or main bundle, or still carries the old key mark (rebrand-web-vault.py not run). Runs as the gateway's
wrangler build step, so `wrangler deploy -c gw/wrangler.jsonc` stops before uploading anything. (11-24: a deploy from an
empty folder left pass.azet.io answering 404.)"""
import glob, os, sys

W = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "public", "web-vault")
OLD = "M13 1a8 8 0 1 1 0 16a8 8 0 0 1 0-16Z"
files = [f for f in glob.glob(os.path.join(W, "**", "*"), recursive=True) if os.path.isfile(f)]
bundles = glob.glob(os.path.join(W, "app", "main.*.js"))
problems = []
if len(files) < 40: problems.append(f"{len(files)} files (a built web vault has hundreds)")
if not os.path.isfile(os.path.join(W, "index.html")): problems.append("no index.html")
if not bundles: problems.append("no app/main.*.js")
old = [os.path.relpath(f, W) for f in glob.glob(os.path.join(W, "**", "*.js"), recursive=True) if OLD in open(f, encoding="utf-8", errors="ignore").read()]
if old: problems.append("old key mark in " + ", ".join(old) + " (run tools/rebrand-web-vault.py)")
if problems:
    print("web vault check FAILED for " + os.path.abspath(W) + ": " + "; ".join(problems), file=sys.stderr); sys.exit(1)
print(f"web vault check ok: {len(files)} files")
