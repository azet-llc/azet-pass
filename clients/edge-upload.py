#!/usr/bin/env python3
"""Uploads the AZET Pass extension to Microsoft Edge Add-ons and submits it for review (Edge Add-ons API v1.1).
The API key and client id come from the key vault (EDGE_ADDONS_AZET__API_KEY / __CLIENT_ID); nothing secret is printed.
Usage: edge-upload.py VERSION PRODUCT_ID [--dry-run]
PRODUCT_ID is the product's GUID in Partner Center (Edge > the extension > the address bar), not the store id.
AZET Pass Password Manager = 622b53b7-52e1-4b64-ab23-358938fd1760 (store id 0RDCKFMJNCX4)."""
import json, os, subprocess, sys, time, urllib.request, urllib.error

VERSION, PRODUCT = sys.argv[1], sys.argv[2]
ZIP = os.path.expanduser(f"~/Code/azet-pass-work/dist/azet-pass-edge-{VERSION}.zip")
API = f"https://api.addons.microsoftedge.microsoft.com/v1/products/{PRODUCT}/submissions"
vault = lambda name: subprocess.run(["tkt", "get", name], capture_output=True, text=True).stdout.strip()
HEAD = {"Authorization": "ApiKey " + vault("EDGE_ADDONS_AZET__API_KEY"), "X-ClientID": vault("EDGE_ADDONS_AZET__CLIENT_ID")}


def call(method, url, body=None, content_type=None):
    req = urllib.request.Request(url, method=method, data=body, headers={**HEAD, **({"Content-Type": content_type} if content_type else {})})
    try:
        r = urllib.request.urlopen(req, timeout=300)
        return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers), e.read().decode()[:400]


def wait(url):
    for _ in range(60):
        status, _, text = call("GET", url)
        state = (json.loads(text or "{}").get("status") or "").lower() if status == 200 else ""
        if state and state != "inprogress":
            return state, text[:400]
        time.sleep(5)
    return "timeout", ""


print("package", os.path.getsize(ZIP), "bytes")
if "--dry-run" in sys.argv:
    # an operation id that cannot exist: 404 means the key, client id and product id were accepted, 401/403 that they were not
    print("dry-run: status", call("GET", f"{API}/draft/package/operations/00000000-0000-0000-0000-000000000000")[0])
    sys.exit(0)
status, headers, text = call("POST", f"{API}/draft/package", open(ZIP, "rb").read(), "application/zip")
print("upload:", status, text[:200])
if status != 202:
    sys.exit(1)
state, text = wait(f"{API}/draft/package/operations/{headers['Location'].rsplit('/', 1)[-1]}")
print("package check:", state, text)
if state != "succeeded":
    sys.exit(1)
notes = f"AZET Pass {VERSION}: rebuilt on the upstream {VERSION.rsplit('.', 1)[0]} release (bug and security fixes). No new permissions."
status, headers, text = call("POST", API, json.dumps({"notes": notes}).encode(), "application/json")
print("publish:", status, text[:200])
if status != 202:
    sys.exit(1)
print("submission:", *wait(f"{API}/operations/{headers['Location'].rsplit('/', 1)[-1]}"))
