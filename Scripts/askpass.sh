#!/bin/sh
# Prints the guest password of the bundle named by MACPOOL_BUNDLE for ssh's askpass hook.
exec plutil -extract password raw -o - "$MACPOOL_BUNDLE/guest-account.json"
