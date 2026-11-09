#!/bin/sh
# Rejects dependencies whose licenses this repository does not accept.
#
# The script resolves the package graph and reads the license file of every pinned package and
# every binary artifact. MIT, BSD, and Apache 2.0 licenses pass. GPL, LGPL, AGPL, and the
# Functional Source License fail, and so does a missing or unrecognized license, which needs a
# person to read it.
#
# Usage: Scripts/check-licenses.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/Scripts/toolchain.sh"
cd "$root"
xcrun swift package resolve >/dev/null

# Prints the license family of a license file.
classify() {
    if grep -qiE 'GNU (AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC LICENSE' "$1"; then
        echo GPL
    elif grep -qiE 'Functional Source License|FSL-1\.[0-9]' "$1"; then
        echo FSL
    elif grep -q 'Apache License' "$1" && grep -q 'Version 2.0' "$1"; then
        echo Apache-2.0
    elif grep -q 'Permission is hereby granted, free of charge' "$1"; then
        echo MIT
    elif grep -q 'Redistribution and use in source and binary forms' "$1"; then
        echo BSD
    else
        echo unknown
    fi
}

# Checks the license file in a directory and records a failure.
check() {
    name=$1
    directory=$2
    file=$(find "$directory" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'COPYING*' \) | sort | sed -n 1p)
    if [ -z "$file" ]; then
        echo "$name: no license file in $directory" >&2
        failed=1
        return
    fi
    license=$(classify "$file")
    case $license in
        MIT | BSD | Apache-2.0) echo "$name: $license" ;;
        *)
            echo "$name: $license license in $file is not accepted" >&2
            failed=1
            ;;
    esac
}

failed=0
count=$(plutil -extract pins raw -o - Package.resolved)
index=0
while [ "$index" -lt "$count" ]; do
    location=$(plutil -extract "pins.$index.location" raw -o - Package.resolved)
    name=$(basename "$location" .git)
    check "$name" ".build/checkouts/$name"
    index=$((index + 1))
done
for bundle in .build/artifacts/*/*/*.artifactbundle .build/artifacts/*/*/*.xcframework; do
    [ -e "$bundle" ] || continue
    check "$(basename "$bundle")" "$bundle"
done
exit "$failed"
