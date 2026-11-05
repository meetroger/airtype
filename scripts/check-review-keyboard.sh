#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -module-cache-path "$check_dir/cache" \
    Sources/Views/FloatingWindow.swift Tests/ReviewKeyboardChecks.swift \
    -o "$check_dir/review-keyboard-checks"
"$check_dir/review-keyboard-checks"
