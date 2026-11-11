#!/bin/bash
# anylinuxfs-automount: sleep hook
#
# Run by sleepwatcher (as root) right before the Mac goes to sleep. It unmounts every
# anylinuxfs drive and stops its microVM, so nothing holds the raw /dev/diskN open
# while the Mac sleeps.
#
# Why: if a dock or USB hub drops the drive during sleep, the kernel has to tear down
# the old disk device on wake. While an anylinuxfs VM still has it open, the teardown
# never finishes, and after 60 s watchdogd panics the machine:
#   panic: busy timeout[1], (60s): 'IOMediaBSDClient'
#
# macOS waits for this script before sleeping, but only for about 30 seconds.

ANYLINUXFS="${ANYLINUXFS:-/opt/homebrew/bin/anylinuxfs}"
RESUME="/var/run/anylinuxfs-automount.resume"
UNMOUNT_WAIT=12      # seconds to wait for each VM to exit after a clean unmount

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [sleep] $*"; }

# BSD name -> IOMedia registry id
media_id() {
    ioreg -r -c IOMedia -w0 -l -d1 | awk -v want="$1" '
        /^\+-o/ { match($0, /id 0x[0-9a-f]+/); id = substr($0, RSTART + 3, RLENGTH - 3) }
        /"BSD Name" = / { b = $NF; gsub(/"/, "", b); if (b == want) { print id; exit } }'
}

vm_running() { pgrep -f "anylinuxfs mount .*/dev/$1\$" >/dev/null; }

# "diskXsY<TAB>/Volumes/<label>" for every anylinuxfs NFS mount
mount | sed -n 's/^\(disk[0-9]*s[0-9]*\)\.local:[^ ]* on \(.*\) (nfs.*/\1	\2/p' |
while IFS=$'\t' read -r dev mp; do
    # Remember the attachment, so the wake hook can have it mounted again
    id=$(media_id "$dev")
    [ -n "$id" ] && echo "$id" >> "$RESUME"

    log "unmounting /dev/$dev ($mp)"
    "$ANYLINUXFS" unmount -w "$UNMOUNT_WAIT" "$mp" >/dev/null 2>&1
    if mount | grep -q "^${dev}\.local:"; then
        log "/dev/$dev: clean unmount failed (open files?), forcing it"
        umount -f "$mp" 2>/dev/null
    fi
    if vm_running "$dev"; then
        "$ANYLINUXFS" stop -f "/dev/$dev" >/dev/null 2>&1
        sleep 2
    fi
    if vm_running "$dev"; then
        pkill -9 -f "anylinuxfs mount .*/dev/$dev\$"
        log "/dev/$dev: VM killed"
    fi
    log "/dev/$dev done"
done

# A VM without a mount (e.g. one that failed half-way) must not hold a disk either
if pgrep -f "anylinuxfs mount " >/dev/null; then
    log "stopping leftover anylinuxfs VMs"
    "$ANYLINUXFS" stop -f >/dev/null 2>&1
fi
exit 0
