#!/usr/bin/env python3
"""Resources/Localizable.xcstrings from the keys the compiler emitted (.stringsdata in DerivedData) + tools/ko.py.
usage: tools/make-strings.py <derived-data-dir>   (build once first). Prints keys that still lack Korean."""
import glob, json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from ko import KO
keys = set()
for f in glob.glob(os.path.join(sys.argv[1], 'Build/Intermediates.noindex/**/*.stringsdata'), recursive=True):
    for ents in json.load(open(f)).get('tables', {}).values():
        keys.update(e['key'] for e in ents)
out = {"sourceLanguage": "en", "version": "1.0", "strings": {}}
missing = []
for k in sorted(keys):
    if k in KO:
        out["strings"][k] = {"localizations": {"ko": {"stringUnit": {"state": "translated", "value": KO[k]}}}}
    else:
        out["strings"][k] = {}
        missing.append(k)
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
json.dump(out, open(os.path.join(here, 'Resources/Localizable.xcstrings'), 'w'), ensure_ascii=False, indent=2)
print(f"{len(keys)} keys, {len(missing)} without ko")
for m in missing: print("  missing:", json.dumps(m, ensure_ascii=False))
