#!/bin/sh
# Rejects dependencies whose licenses this repository does not accept.
#
# The script resolves the package graph and reads the license file of every pinned package and
# every binary artifact. MIT, BSD, ISC, and Apache 2.0 licenses pass. GPL, LGPL, AGPL, and the
# Functional Source License fail, and so does a missing or unrecognized license, which needs a
# person to read it.
#
# A package's NOTICE file names the licenses of code that the package embeds, such as the
# BoringSSL sources that swift-crypto compiles into the binary. Each `LICENSE (NAME):` entry in it
# must name an accepted license, and a NOTICE that mentions a rejected license fails.
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
    elif grep -qE 'Permission to use, copy, modify, (and/or )?(and )?distribute this software for any' "$1"; then
        echo ISC
    else
        echo unknown
    fi
}

# Prints the license family of a name in a NOTICE entry such as "LICENSE (MIT):".
classify_name() {
    case $1 in
        "Apache License 2.0" | "Apache License, Version 2.0" | Apache-2.0) echo Apache-2.0 ;;
        MIT | "MIT License") echo MIT ;;
        BSD | BSD-*) echo BSD ;;
        ISC | "ISC License") echo ISC ;;
        *) echo unknown ;;
    esac
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
        MIT | BSD | ISC | Apache-2.0) echo "$name: $license" ;;
        *)
            echo "$name: $license license in $file is not accepted" >&2
            failed=1
            ;;
    esac
}

# Checks the licenses that the NOTICE file in a directory names and records a failure.
check_notice() {
    name=$1
    directory=$2
    file=$(find "$directory" -maxdepth 1 -type f -iname 'NOTICE*' | sort | sed -n 1p)
    [ -n "$file" ] || return 0
    if grep -qiE 'GNU (AFFERO |LESSER |LIBRARY )?GENERAL PUBLIC LICENSE|Functional Source License|FSL-1\.[0-9]' "$file"; then
        echo "$name: $file names a license that is not accepted" >&2
        failed=1
        return
    fi
    entries=$(sed -n 's/^[[:space:]]*\* LICENSE (\(.*\)):[[:space:]]*$/\1/p' "$file" | sort -u)
    # A here-document keeps the loop in this shell, so a failure it records survives the loop.
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case $(classify_name "$entry") in
            unknown)
                echo "$name: $entry license in $file is not accepted" >&2
                failed=1
                ;;
            *) echo "$name: NOTICE names $entry" ;;
        esac
    done <<EOF
$entries
EOF
}

failed=0
count=$(plutil -extract pins raw -o - Package.resolved)
index=0
while [ "$index" -lt "$count" ]; do
    location=$(plutil -extract "pins.$index.location" raw -o - Package.resolved)
    name=$(basename "$location" .git)
    check "$name" ".build/checkouts/$name"
    check_notice "$name" ".build/checkouts/$name"
    index=$((index + 1))
done
for bundle in .build/artifacts/*/*/*.artifactbundle .build/artifacts/*/*/*.xcframework; do
    [ -e "$bundle" ] || continue
    check "$(basename "$bundle")" "$bundle"
    check_notice "$(basename "$bundle")" "$bundle"
done
exit "$failed"
