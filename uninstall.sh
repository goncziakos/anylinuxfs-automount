#!/bin/bash
# Removes anylinuxfs-automount. Usage: sudo ./uninstall.sh
set -euo pipefail

LABEL="hu.goncziakos.anylinuxfs-automount"
LIBEXEC="/usr/local/libexec"

[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo: sudo ./uninstall.sh" >&2; exit 1; }

launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" \
      "$LIBEXEC/anylinuxfs-automount" "$LIBEXEC/anylinuxfs-automount.sh" \
      /var/run/anylinuxfs-automount.handled
rmdir /var/run/anylinuxfs-automount.lock 2>/dev/null || true

cat <<EOF
Uninstalled. Drives that are mounted now stay mounted.
Left in place: the log (/var/log/anylinuxfs-automount.log) and the Full Disk Access
entry, which you can remove in System Settings -> Privacy & Security -> Full Disk Access.
EOF
