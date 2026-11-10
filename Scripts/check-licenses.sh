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
# read, and the script fails on any NOTICE file without exactly one matching record. The same list
# records the BoringSSL revision that swift-crypto compiles into the binary, which no NOTICE names,
# and the script fails when the revision changes or lacks exactly one record.
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

# Prints how many lines of the review list record a file, followed by the value on the last one.
recorded() {
    awk -v kind="$1" -v path="$2" '$1 == kind && $2 == path { count++; value = $3 } END { print count + 0, value }' "$review"
}

# Prints the value that the review list records for a file under .build.
#
# A NOTICE file's value is the SHA-256 digest of its text, and a hash.txt file's value is the
# BoringSSL revision that it names.
reviewed_value() {
    case $1 in
        notice) shasum -a 256 ".build/$2" | cut -d ' ' -f 1 ;;
        boringssl) sed -n 's/.* at revision \([0-9a-f]*\).*/\1/p' ".build/$2" ;;
    esac
}

# Checks every NOTICE file and BoringSSL revision of the resolved packages and binary artifacts
# against the review list.
check_notices() {
    # Paths relative to .build match the review list. Symbolic links count, because a link can
    # replace a reviewed file, and the check reads the file that a link points to.
    found=$(cd .build && {
        find checkouts artifacts \( -type f -o -type l \) -iname 'NOTICE*' -not -path '*/.git/*' |
            sed 's/^/notice /'
        find checkouts \( -type f -o -type l \) -path '*/CCryptoBoringSSL/hash.txt' | sed 's/^/boringssl /'
    } 2>/dev/null | sort)
    # A here-document keeps the loop in this shell, so a failure it records survives the loop.
    while read -r kind path; do
        [ -n "$kind" ] || continue
        if [ ! -f ".build/$path" ] || [ ! -r ".build/$path" ]; then
            echo "$path: not a readable file" >&2
            failed=1
            continue
        fi
        value=$(reviewed_value "$kind" "$path")
        record=$(recorded "$kind" "$path")
        count=${record%% *}
        if [ "$count" -gt 1 ]; then
            echo "$path: recorded $count times in Scripts/license-review.txt. Keep one line." >&2
            failed=1
        elif [ -z "$value" ]; then
            echo "$path: names no BoringSSL revision" >&2
            failed=1
        elif [ "$count" -eq 0 ]; then
            echo "$path: not in Scripts/license-review.txt. Read it and record $value." >&2
            failed=1
        elif [ "${record#* }" != "$value" ]; then
            echo "$path: changed since its review. Read it and record $value." >&2
            failed=1
        else
            echo "$path: reviewed"
        fi
    done <<EOF
$found
EOF
    while read -r kind path rest; do
        case $kind in
            '' | '#'*) ;;
            notice | boringssl)
                if [ ! -f ".build/$path" ]; then
                    echo "$path: recorded in Scripts/license-review.txt but missing. Remove its line." >&2
                    failed=1
                fi
                ;;
            *)
                echo "Scripts/license-review.txt: unknown kind $kind" >&2
                failed=1
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
