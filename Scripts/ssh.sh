#!/bin/sh
# Runs a command in a provisioned guest over SSH with the account stored in its bundle.
#
# The script ignores the user's SSH configuration and agent, so no host key or identity leaves
# the host. Each bundle keeps its own known_hosts file, which names the guest by a fixed alias
# instead of its address, because the address can change between boots. Only Ed25519 host keys
# count. A clone's first run pins its new key there, and a guest that presents another key is
# refused. ssh splits option values on spaces, so the file's path is quoted inside the option for
# bundle paths that contain them.
#
# A clone whose credential rotation is pending or unfinished has no usable account, so the
# script refuses it.
#
# Usage: Scripts/ssh.sh BUNDLE [command...]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bundle=$(cd "$1" && pwd)
shift
rotation=$(plutil -extract credential_rotation raw -o - "$bundle/settings.json" 2>/dev/null || true)
case $rotation in
    pending)
        echo "$bundle still has its source's guest credentials. macpool run replaces them." >&2
        exit 1
        ;;
    started)
        echo "$bundle did not finish replacing its guest credentials. Delete it and clone again." >&2
        exit 1
        ;;
esac
address=$("${MACPOOL_BINARY:-$root/.build/release/macpool}" ip --bundle "$bundle")
user=$(plutil -extract username raw -o - "$bundle/guest-account.json")
MACPOOL_BUNDLE=$bundle SSH_ASKPASS="$root/Scripts/askpass.sh" SSH_ASKPASS_REQUIRE=force \
    exec ssh -F /dev/null -o ForwardAgent=no -o IdentityAgent=none -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o "UserKnownHostsFile=\"$bundle/known_hosts\"" -o GlobalKnownHostsFile=/dev/null \
    -o HostKeyAlias=macpool-guest -o HostKeyAlgorithms=ssh-ed25519 -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 "$user@$address" "$@"
