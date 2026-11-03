#!/bin/bash
# Builds and installs anylinuxfs-automount as a system LaunchDaemon.
# Usage: sudo ./install.sh
set -euo pipefail

LABEL="hu.goncziakos.anylinuxfs-automount"
LIBEXEC="/usr/local/libexec"
LAUNCHER="$LIBEXEC/anylinuxfs-automount"
SCRIPT="$LIBEXEC/anylinuxfs-automount.sh"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG="/var/log/anylinuxfs-automount.log"

# Earlier, unpublished version of this tool (removed if present)
LEGACY_LABEL="hu.goncziakos.ext4-automount"

cd "$(dirname "$0")"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only"
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo ./install.sh"
USER_NAME="${SUDO_USER:-}"
[ -n "$USER_NAME" ] && [ "$USER_NAME" != "root" ] || die "run via sudo from your normal user account"
USER_UID=$(id -u "$USER_NAME")
USER_GID=$(id -g "$USER_NAME")
USER_HOME=$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | awk '{print $2}')

ANYLINUXFS="${ANYLINUXFS:-}"
if [ -z "$ANYLINUXFS" ]; then
    for p in /opt/homebrew/bin/anylinuxfs /usr/local/bin/anylinuxfs; do
        [ -x "$p" ] && ANYLINUXFS="$p" && break
    done
fi
[ -n "$ANYLINUXFS" ] && [ -x "$ANYLINUXFS" ] \
    || die "anylinuxfs not found (brew install nohajc/anylinuxfs/anylinuxfs, or set ANYLINUXFS=/path)"
[ -d "$USER_HOME/.anylinuxfs" ] \
    || die "anylinuxfs is not initialised for $USER_NAME; run 'anylinuxfs init' (or mount a drive once by hand) first"
command -v cc >/dev/null || die "no C compiler; install the Xcode Command Line Tools: xcode-select --install"

echo "==> Building launcher"
mkdir -p build
cc -O2 -Wall -Wextra -DSCRIPT_PATH="\"$SCRIPT\"" -o build/anylinuxfs-automount src/launcher.c

echo "==> Removing previous installation (if any)"
for l in "$LABEL" "$LEGACY_LABEL"; do
    launchctl bootout "system/$l" 2>/dev/null || true
done
rm -f "/Library/LaunchDaemons/$LEGACY_LABEL.plist" \
      "$LIBEXEC/ext4-automount" "$LIBEXEC/ext4-automount.sh"

echo "==> Installing files"
install -d -o root -g wheel -m 755 "$LIBEXEC"
install -o root -g wheel -m 755 build/anylinuxfs-automount "$LAUNCHER"
install -o root -g wheel -m 755 src/anylinuxfs-automount.sh "$SCRIPT"
sed -e "s|@LABEL@|$LABEL|g" \
    -e "s|@LAUNCHER@|$LAUNCHER|g" \
    -e "s|@ANYLINUXFS@|$ANYLINUXFS|g" \
    -e "s|@ANYLINUXFS_DIR@|$(dirname "$ANYLINUXFS")|g" \
    -e "s|@HOME@|$USER_HOME|g" \
    -e "s|@USER@|$USER_NAME|g" \
    -e "s|@UID@|$USER_UID|g" \
    -e "s|@GID@|$USER_GID|g" \
    -e "s|@LOG@|$LOG|g" \
    launchd/anylinuxfs-automount.plist.in > "$PLIST"
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null

echo "==> Starting LaunchDaemon $LABEL"
launchctl bootstrap system "$PLIST"

cat <<EOF

Installed. One manual step is left:

  Grant Full Disk Access to the launcher, otherwise macOS blocks access to the drives:
    System Settings -> Privacy & Security -> Full Disk Access -> "+"
    press Cmd+Shift+G, type:  $LAUNCHER
    and switch it on.

  Then restart the daemon:
    sudo launchctl kickstart -k system/$LABEL

Log: $LOG
EOF
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
