#!/usr/bin/env python3
"""inject-file.py <page id> <file> <accept> [n]: hands a local file to a page's hidden file input (the one with that accept
value, shadow parts included) through the AZET browser, in pieces, for pages whose upload button the upload command cannot reach."""
import base64, json, subprocess, sys
page, path, accept = sys.argv[1:4]
nth = int(sys.argv[4]) if len(sys.argv) > 4 else -1  # which of the inputs with that accept (default: the last)
def ev(js):
    r = subprocess.run(["azet-desktop", "eval", "--page", page, "--expression", js, "--json"], capture_output=True, text=True)
    d = json.loads(r.stdout or "{}")
    if not d.get("ok"): raise SystemExit(str(d)[:300])
    return (d.get("result") or {}).get("result")
data = base64.b64encode(open(path, "rb").read()).decode()
N = 48_000  # a multiple of 4, so each piece decodes on its own
ev("window.__f = []; 0")
for i in range(0, len(data), N):
    ev(f"window.__f.push(Uint8Array.from(atob('{data[i:i+N]}'), c => c.charCodeAt(0))); window.__f.length")
name = path.split("/")[-1]
print(ev("(()=>{const all=[];const walk=(r)=>{for(const e of r.querySelectorAll('*')){if(e.tagName==='INPUT'&&e.type==='file'&&e.accept===%s)all.push(e);if(e.shadowRoot)walk(e.shadowRoot)}};walk(document);const inp=all.at(%d);if(!inp)return 'no input';const f=new File(window.__f,%s,{type:'application/octet-stream'});window.__f=null;const dt=new DataTransfer();dt.items.add(f);inp.files=dt.files;inp.dispatchEvent(new Event('change',{bubbles:true}));return 'set '+f.size})()" % (json.dumps(accept), nth, json.dumps(name))))
