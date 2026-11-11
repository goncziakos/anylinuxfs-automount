#!/bin/bash
# anylinuxfs-automount: wake hook
#
# Run by sleepwatcher (as root) after the Mac wakes up. It forgets the attachments the
# sleep hook unmounted, so the automount daemon mounts them again within a few seconds,
# if the drive is still there. A drive that was replugged gets a new id and is mounted
# anyway.

LOCK="/var/run/anylinuxfs-automount.lock"
HANDLED="/var/run/anylinuxfs-automount.handled"
RESUME="/var/run/anylinuxfs-automount.resume"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [wake] $*"; }

[ -s "$RESUME" ] || exit 0

# Same lock as the automount script, so we never edit HANDLED under its feet
for _ in $(seq 1 60); do mkdir "$LOCK" 2>/dev/null && break; sleep 1; done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

if [ -f "$HANDLED" ]; then
    grep -vxF -f "$RESUME" "$HANDLED" > "$HANDLED.tmp"
    mv "$HANDLED.tmp" "$HANDLED"
fi
log "will mount again: $(tr '\n' ' ' < "$RESUME")"
rm -f "$RESUME"
exit 0
