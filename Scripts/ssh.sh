#!/bin/sh
# Runs a command in a provisioned guest over SSH with the account stored in its bundle.
#
# The script ignores the user's SSH configuration and agent, so no host key or identity leaves
# the host. Each bundle keeps its own known_hosts file. ssh splits option values on spaces, so the
# file's path is quoted inside the option for bundle paths that contain them.
#
# Usage: Scripts/ssh.sh BUNDLE [command...]
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
bundle=$(cd "$1" && pwd)
shift
address=$("${MACPOOL_BINARY:-$root/.build/release/macpool}" ip --bundle "$bundle")
user=$(plutil -extract username raw -o - "$bundle/guest-account.json")
MACPOOL_BUNDLE=$bundle SSH_ASKPASS="$root/Scripts/askpass.sh" SSH_ASKPASS_REQUIRE=force \
    exec ssh -F /dev/null -o ForwardAgent=no -o IdentityAgent=none -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o "UserKnownHostsFile=\"$bundle/known_hosts\"" -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 "$user@$address" "$@"
