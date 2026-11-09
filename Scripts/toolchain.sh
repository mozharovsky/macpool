# Selects the pinned Xcode for the sourcing script without changing the machine's selection.
#
# The pin lives in .xcode-version. A DEVELOPER_DIR that the caller set wins over the standard
# install location of the pinned version. The script stops when the selected Xcode is another
# version, because the package needs that version's macOS SDK.
pinned=$(cat "$root/.xcode-version")
if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="/Applications/Xcode_$pinned.app/Contents/Developer"
fi
export DEVELOPER_DIR
selected=$(xcodebuild -version | sed -n 1p)
if [ "$selected" != "Xcode $pinned" ]; then
    echo "DEVELOPER_DIR selects $selected. This repository pins Xcode $pinned." >&2
    exit 1
fi
