#!/bin/sh
# Builds the release binary and signs it ad hoc with the virtualization entitlement.
#
# Virtualization refuses to create a VM in a process without the
# com.apple.security.virtualization entitlement. SwiftPM does not sign with entitlements, so
# every binary that starts a VM comes from this script.
#
# Usage: Scripts/build.sh [swift build arguments]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/Scripts/toolchain.sh"
cd "$root"
xcrun swift build --configuration release --product macpool "$@"
binary="$(xcrun swift build --configuration release --show-bin-path "$@")/macpool"
codesign --force --sign - --entitlements "$root/macpool.entitlements" "$binary"
codesign --display --entitlements - "$binary" 2>/dev/null | grep -q com.apple.security.virtualization
echo "$binary"
