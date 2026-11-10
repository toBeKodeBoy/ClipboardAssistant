#!/usr/bin/env bash
# Portable subset of the real XCTest suite; never substitutes for macOS xcodebuild.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/clipboard-snippets.XXXXXX)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/ClipboardAssistant" "$work/Sources/SQLite3" "$work/Tests/ClipboardAssistantTests"
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ClipboardAssistant", products: [], targets: [
    .systemLibrary(name: "SQLite3", pkgConfig: "sqlite3"),
    .target(name: "ClipboardAssistant", dependencies: ["SQLite3"]),
    .testTarget(name: "ClipboardAssistantTests", dependencies: ["ClipboardAssistant"])
])
SWIFT
printf 'module SQLite3 [system] { header "/usr/include/sqlite3.h" link "sqlite3" export * }\n' > "$work/Sources/SQLite3/module.modulemap"
for file in Domain/L10n.swift Domain/Snippet.swift Domain/SnippetTemplate.swift Storage/AppPaths.swift Storage/SQLiteDatabase.swift Storage/SnippetStore.swift; do
    if [[ -f "$repo/$file" ]]; then cp "$repo/$file" "$work/Sources/ClipboardAssistant/"; fi
done
cp "$repo/Tests/SnippetTests.swift" "$repo/Tests/SnippetStoreTests.swift" "$work/Tests/ClipboardAssistantTests/"
cd "$work"
swift test --enable-code-coverage
if [[ -n "${SNIPPET_COVERAGE_DIR:-}" ]]; then
    mkdir -p "$SNIPPET_COVERAGE_DIR"
    cp .build/debug/codecov/*.json "$SNIPPET_COVERAGE_DIR/"
fi
