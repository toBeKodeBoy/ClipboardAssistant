#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/clipboard-rules.XXXXXX)
mkdir -p "$work/Sources/ClipboardAssistant" "$work/Tests/ClipboardAssistantTests" "$work/Sources/SQLite3"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ClipboardAssistant", targets: [
 .systemLibrary(name: "SQLite3", pkgConfig: "sqlite3"),
 .target(name: "ClipboardAssistant", dependencies: ["SQLite3"]),
 .testTarget(name: "ClipboardAssistantTests", dependencies: ["ClipboardAssistant"])
])
SWIFT
printf 'module SQLite3 [system] { header "%s" link "sqlite3" export * }\n' "${SQLITE_HEADER:-/usr/include/sqlite3.h}" > "$work/Sources/SQLite3/module.modulemap"
for file in Storage/RuleStore.swift Storage/SQLiteDatabase.swift Storage/AppPaths.swift Domain/L10n.swift Domain/ItemKind.swift Domain/CaptureRules.swift Domain/HistoryArchive.swift Features/Privacy/PrivacyGate.swift; do
 if [[ -f "$repo/$file" ]]; then cp "$repo/$file" "$work/Sources/ClipboardAssistant/"; fi
done
cp "$repo/Tests/RuleStoreTests.swift" "$repo/Tests/RulesTests.swift" "$repo/Tests/HistoryArchiveTests.swift" "$work/Tests/ClipboardAssistantTests/"
cd "$work"
swift test --enable-code-coverage "$@"
if [[ -n "${RULES_COVERAGE_DIR:-}" ]]; then
 mkdir -p "$RULES_COVERAGE_DIR"
 cp .build/debug/codecov/*.json "$RULES_COVERAGE_DIR/"
fi
