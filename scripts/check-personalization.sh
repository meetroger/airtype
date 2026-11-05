#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/cache" \
    Sources/Services/DictationPersonalization.swift Tests/PersonalizationChecks.swift \
    -o "$check_dir/checks"
"$check_dir/checks"
xcrun swiftc -module-cache-path "$check_dir/cache" \
    Sources/Services/TranscriptionHistory.swift Tests/HistoryChecks.swift \
    -o "$check_dir/history-checks"
"$check_dir/history-checks"
xcrun swiftc -module-cache-path "$check_dir/cache" \
    Sources/Services/DictationPersonalization.swift Sources/Services/EditLearning.swift \
    Tests/EditLearningChecks.swift -o "$check_dir/edit-learning-checks"
"$check_dir/edit-learning-checks"
