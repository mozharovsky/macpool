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
# Bundles from older versions pinned the guest's Ed25519 key under its address. The script
# copies such keys and any revocations of Ed25519 keys to the alias before it connects, so they
# keep applying.
#
# A clone whose credential rotation is pending or unfinished has no usable account, so the
# script refuses it. A running macpool run on the bundle means the rotation is still under way.
#
# Usage: Scripts/ssh.sh BUNDLE [command...]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bundle=$(cd "$1" && pwd)
shift
macpool=${MACPOOL_BINARY:-$root/.build/release/macpool}
rotation=$(plutil -extract credential_rotation raw -o - "$bundle/settings.json" 2>/dev/null || true)
case $rotation in
    pending | started)
        if "$macpool" ip --bundle "$bundle" >/dev/null 2>&1; then
            echo "macpool run is replacing the guest credentials of $bundle. Wait until it prints ready." >&2
        elif [ "$rotation" = pending ]; then
            echo "$bundle still has its source's guest credentials. macpool run replaces them." >&2
        else
            echo "$bundle did not finish replacing its guest credentials. Delete it and clone again." >&2
        fi
        exit 1
        ;;
esac
known_hosts=$bundle/known_hosts
if [ -f "$known_hosts" ]; then
    revoked=$(awk '$1 == "@revoked" && $3 == "ssh-ed25519" { keys[$4] = 1; if (("," $2 ",") ~ /,macpool-guest,/) done[$4] = 1 }
        END { for (key in keys) if (!(key in done)) print "@revoked macpool-guest ssh-ed25519 " key }' "$known_hosts")
    if [ -n "$revoked" ]; then
        printf "%s\n" "$revoked" >>"$known_hosts"
    fi
fi
if [ -f "$known_hosts" ] && ! awk '$1 !~ /^[#@]/ && ("," $1 ",") ~ /,macpool-guest,/ { found = 1 } END { exit !found }' "$known_hosts"; then
    legacy=$(awk '$1 !~ /^[#@]/ && $2 == "ssh-ed25519" { print "macpool-guest ssh-ed25519 " $3 }' "$known_hosts")
    if [ -n "$legacy" ]; then
        printf "%s\n" "$legacy" >>"$known_hosts"
    fi
fi
address=$("$macpool" ip --bundle "$bundle")
user=$(plutil -extract username raw -o - "$bundle/guest-account.json")
MACPOOL_BUNDLE=$bundle SSH_ASKPASS="$root/Scripts/askpass.sh" SSH_ASKPASS_REQUIRE=force \
    exec ssh -F /dev/null -o ForwardAgent=no -o IdentityAgent=none -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o "UserKnownHostsFile=\"$known_hosts\"" -o GlobalKnownHostsFile=/dev/null \
    -o HostKeyAlias=macpool-guest -o HostKeyAlgorithms=ssh-ed25519 -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 "$user@$address" "$@"
