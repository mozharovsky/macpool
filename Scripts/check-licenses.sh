#!/bin/sh
# Rejects dependencies whose licenses this repository does not accept.
#
# The script resolves the package graph and reads the license file of every pinned package and
# every binary artifact. MIT, BSD, ISC, and Apache 2.0 licenses pass. GPL, LGPL, AGPL, and the
# Functional Source License fail, and so does a missing or unrecognized license, which needs a
# person to read it.
#
# NOTICE files name the licenses of code that a package embeds in free text, which the script
# does not parse. Scripts/license-review.txt records the digest of every NOTICE file that a person
# read, and the script fails on any NOTICE file without a matching record. The same list records
# the BoringSSL revision that swift-crypto compiles into the binary, which no NOTICE names, and
# the script fails when the revision changes.
#
# Usage: Scripts/check-licenses.sh
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/Scripts/toolchain.sh"
cd "$root"
xcrun swift package resolve >/dev/null
review="$root/Scripts/license-review.txt"

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

# Prints the field after the kind and path of a line in the review list, or nothing without a line.
recorded() {
    awk -v kind="$1" -v path="$2" '$1 == kind && $2 == path { print $3 }' "$review"
}

# Checks every NOTICE file of the resolved packages and binary artifacts against the review list.
check_notices() {
    # Paths relative to .build match the review list.
    notices=$(cd .build && find checkouts artifacts -type f -iname 'NOTICE*' -not -path '*/.git/*' 2>/dev/null | sort)
    # A here-document keeps the loop in this shell, so a failure it records survives the loop.
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        digest=$(shasum -a 256 ".build/$path" | cut -d ' ' -f 1)
        case $(recorded notice "$path") in
            "$digest") echo "$path: reviewed" ;;
            "")
                echo "$path: not in Scripts/license-review.txt. Read it and record digest $digest." >&2
                failed=1
                ;;
            *)
                echo "$path: changed since its review. Read it and record digest $digest." >&2
                failed=1
                ;;
        esac
    done <<EOF
$notices
EOF
    while read -r kind path value licenses; do
        case $kind in
            notice)
                if [ ! -f ".build/$path" ]; then
                    echo "$path: recorded in Scripts/license-review.txt but missing. Remove its line." >&2
                    failed=1
                fi
                ;;
            boringssl)
                revision=$(sed -n 's/.* at revision \([0-9a-f]*\).*/\1/p' ".build/$path" 2>/dev/null || true)
                if [ "$revision" = "$value" ]; then
                    echo "BoringSSL $revision: $licenses"
                else
                    echo "$path: BoringSSL revision ${revision:-unreadable} is not the reviewed $value." >&2
                    failed=1
                fi
                ;;
        esac
    done <"$review"
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
check_notices
exit "$failed"
