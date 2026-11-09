#!/bin/sh
# Points Git at the repository's hooks in Scripts/Hooks.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
git -C "$root" config core.hooksPath Scripts/Hooks
echo "Git now runs the hooks in $root/Scripts/Hooks."
