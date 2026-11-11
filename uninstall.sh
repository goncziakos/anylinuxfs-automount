#!/bin/bash
# Removes anylinuxfs-automount. Usage: sudo ./uninstall.sh
set -euo pipefail

LABEL="hu.goncziakos.anylinuxfs-automount"
LIBEXEC="/usr/local/libexec"

[ "$(id -u)" -eq 0 ] || { echo "error: run with sudo: sudo ./uninstall.sh" >&2; exit 1; }

for l in "$LABEL" "$LABEL.sleep"; do
    launchctl bootout "system/$l" 2>/dev/null || true
    rm -f "/Library/LaunchDaemons/$l.plist"
done
rm -f "$LIBEXEC/anylinuxfs-automount" "$LIBEXEC/anylinuxfs-automount.sh" \
      "$LIBEXEC/anylinuxfs-automount-sleep.sh" "$LIBEXEC/anylinuxfs-automount-wake.sh" \
      /var/run/anylinuxfs-automount.handled /var/run/anylinuxfs-automount.resume
rmdir /var/run/anylinuxfs-automount.lock 2>/dev/null || true

cat <<EOF
Uninstalled. Drives that are mounted now stay mounted.
Left in place: the log (/var/log/anylinuxfs-automount.log) and the Full Disk Access
entry, which you can remove in System Settings -> Privacy & Security -> Full Disk Access.
EOF
