#!/usr/bin/env python3
"""Sets the response headers Cloudflare puts on the pass.azet.io web vault (the azet.io zone rule that already carried
its frame-ancestors policy): the full content security policy and a year of HSTS. /team and /invite keep the stricter
headers the gateway Worker gives them (the rule's expression leaves them out). Tried first with
CSP=… server/test/webvault-login.sh. The token comes from the key vault and is never printed.
usage: zone-vault-headers.py [--apply]"""
import json, subprocess, sys, urllib.request, urllib.error

CSP = ("default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data: https://haveibeenpwned.com; "
       "connect-src 'self' https://api.pwnedpasswords.com https://api.2fa.directory wss://pass.azet.io; "
       "child-src 'self' https://*.duosecurity.com https://*.duofederal.com; "
       "frame-src 'self' https://*.duosecurity.com https://*.duofederal.com; object-src 'self' blob:; "
       "frame-ancestors 'self' chrome-extension: moz-extension: safari-web-extension:; base-uri 'self'; form-action 'self'")
WANT = {'Content-Security-Policy': CSP, 'Strict-Transport-Security': 'max-age=31536000; includeSubDomains'}
token = subprocess.run(['tkt', 'get', 'CLOUDFLARE_API_TOKEN'], capture_output=True, text=True).stdout.strip()


def api(method, path, body=None):
    req = urllib.request.Request('https://api.cloudflare.com/client/v4' + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    try:
        return json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        return {'success': False, 'errors': e.read().decode()[:300]}


zone = api('GET', '/zones?name=azet.io')['result'][0]['id']
ruleset = api('GET', f'/zones/{zone}/rulesets/phases/http_response_headers_transform/entrypoint')['result']
mine = [r for r in ruleset['rules'] if 'pass.azet.io' in r['expression'] and 'Content-Security-Policy' in r['action_parameters']['headers']]
assert len(mine) == 1, f'expected one vault rule, found {len(mine)}'
headers = mine[0]['action_parameters']['headers']
print('now:', {k: v.get('value', '')[:70] for k, v in headers.items()})
if '--apply' in sys.argv:
    print('previous rule (to put back):', json.dumps(mine[0]['action_parameters']))
    for name, value in WANT.items():
        headers[name] = {'operation': 'set', 'value': value}
    keep = [{k: v for k, v in r.items() if k in ('action', 'action_parameters', 'expression', 'description', 'enabled')} for r in ruleset['rules']]
    done = api('PUT', f'/zones/{zone}/rulesets/{ruleset["id"]}', {'rules': keep})
    print('applied:', done.get('success'), done.get('errors'))
