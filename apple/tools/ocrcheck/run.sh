#!/bin/bash
# Notebook OCR + parser check on macOS (same Vision engine as iOS). Fails unless the sample page yields the 4 sites.
set -euo pipefail
cd "$(dirname "$0")"; T=$(mktemp -d)
python3 - "$T" <<'PY'
import sys; src=open('../../App/ScanViews.swift').read()
open(sys.argv[1]+'/parser.swift','w').write("import Foundation\n"+src[src.index("struct NotebookEntry"):src.index("enum NotebookOCR")]+src[src.index("/// How people write these pages"):src.index("struct CameraPicker")])
PY
swiftc -O -o "$T/ocr" main.swift "$T/parser.swift" ../../App/Presets.swift
out=$("$T/ocr" notebook-page.jpg); echo "$out"
for s in 네이버 KB국민은행 정부24 쿠팡; do echo "$out" | grep -q "^ENTRY $s |" || { echo "FAIL: $s missing"; exit 1; }; done
echo "PASS: 4 entries"
