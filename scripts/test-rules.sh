#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/clipboard-rules.XXXXXX)
mkdir -p "$work/Sources/ClipboardAssistant" "$work/Tests/ClipboardAssistantTests"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ClipboardAssistant", targets: [
 .target(name: "ClipboardAssistant"),
 .testTarget(name: "ClipboardAssistantTests", dependencies: ["ClipboardAssistant"])
])
SWIFT
for file in Domain/L10n.swift Domain/ItemKind.swift Domain/CaptureRules.swift Domain/HistoryArchive.swift Features/Privacy/PrivacyGate.swift; do
 if [[ -f "$repo/$file" ]]; then cp "$repo/$file" "$work/Sources/ClipboardAssistant/"; fi
done
cp "$repo/Tests/RulesTests.swift" "$repo/Tests/HistoryArchiveTests.swift" "$work/Tests/ClipboardAssistantTests/"
cd "$work"
swift test --enable-code-coverage "$@"
if [[ -n "${RULES_COVERAGE_DIR:-}" ]]; then
 mkdir -p "$RULES_COVERAGE_DIR"
 cp .build/debug/codecov/*.json "$RULES_COVERAGE_DIR/"
fi
