#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# The app builds Copus from its pinned Swift package. Standalone checks can use
# that checkout or Homebrew's libopus; neither requires a BLE device.
opus_prefix=${OPUS_ROOT:-/opt/homebrew/opt/opus}
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
mkdir -p "$check_dir/Copus"
cat > "$check_dir/Copus/module.modulemap" <<EOF
module Copus [system] {
    header "$opus_prefix/include/opus/opus.h"
    link "opus"
    export *
}
EOF
xcrun swiftc -module-cache-path "$check_dir/cache" -I "$check_dir/Copus" \
    -L "$opus_prefix/lib" -lopus Sources/Services/BLEMicProtocol.swift \
    Sources/Services/BLEOpusDecoder.swift Tests/BLEMicChecks.swift -o "$check_dir/checks"
"$check_dir/checks"

xcrun swiftc -module-cache-path "$check_dir/cache" Sources/Services/BLEMicSources.swift \
    Tests/BLEMicSourceChecks.swift -o "$check_dir/source-checks"
"$check_dir/source-checks"
