#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: bash scripts/check-history-transfer-coverage.sh /path/to/Test.xcresult" >&2
  exit 2
fi
report=$(mktemp /tmp/clipboard-coverage.XXXXXX)
trap 'rm -f "$report"' EXIT
xcrun xccov view --report --json "$1" > "$report"
python3 - "$report" <<'PY'
import json, sys
expected = {
    'HistoryArchive.swift', 'ArchiveSchema.swift', 'ArchiveStream.swift',
    'HistoryTransfer.swift', 'HistoryTransferView.swift',
}
report = json.load(open(sys.argv[1]))
files = {f['name']: f for t in report['targets'] if t['name'] == 'ClipboardAssistant.app' for f in t['files'] if f['name'] in expected}
missing = expected - files.keys()
if missing:
    raise SystemExit('Missing coverage: ' + ', '.join(sorted(missing)))
failed = False
for name in sorted(expected):
    f = files[name]
    passed = f['executableLines'] > 0 and f['coveredLines'] == f['executableLines']
    print(f"{name}: {f['coveredLines']}/{f['executableLines']} executable lines {'PASS' if passed else 'FAIL'}")
    failed |= not passed
raise SystemExit(1 if failed else 0)
PY
