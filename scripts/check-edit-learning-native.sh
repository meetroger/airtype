#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/cache" \
    Sources/Services/DictationPersonalization.swift Sources/Services/EditLearning.swift \
    Sources/Services/EditLearningTracker.swift Sources/Services/TextInserter.swift \
    Tests/EditLearningNativeChecks.swift -o "$check_dir/edit-learning-native-checks"
"$check_dir/edit-learning-native-checks" "$@"
