#!/bin/sh
# Shuts a provisioned guest down from inside, which `macpool run` reports as a clean stop.
#
# sudo reads the account's password from standard input, because the SSH session has no
# terminal. The shutdown starts in the background a second later, so the SSH session ends
# normally before the guest closes the connection.
#
# Usage: Scripts/shutdown.sh BUNDLE
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bundle=$(cd "$1" && pwd)
{
    plutil -extract password raw -o - "$bundle/guest-account.json"
    echo
} | "$root/Scripts/ssh.sh" "$bundle" \
    "sudo -S -p '' /bin/sh -c '(sleep 1; /sbin/shutdown -h now) >/dev/null 2>&1 &'"
