#!/bin/bash
# anylinuxfs-automount
#
# Mounts every freshly attached external Linux partition (ext2/3/4) read-write with
# anylinuxfs. For LUKS-encrypted partitions it asks the logged-in user for the
# passphrase in a dialog box.
#
# A LaunchDaemon runs this script every few seconds. Each attachment is handled only
# once (keyed by the IOMedia registry id), so a drive you unmounted by hand is not
# mounted again until you unplug and replug it.

ANYLINUXFS="${ANYLINUXFS:-/opt/homebrew/bin/anylinuxfs}"
LOCK="/var/run/anylinuxfs-automount.lock"
HANDLED="/var/run/anylinuxfs-automount.handled"

LINUX_GPT="0FC63DAF-8483-4772-8E79-3D69D8477DE4"   # GPT "Linux filesystem"
LUKS_GPT="CA7D7CCB-63ED-4C53-861C-1742536059CC"    # GPT "Linux LUKS"

MAX_TRIES=3          # passphrase attempts per attachment
DIALOG_TIMEOUT=120   # seconds before the passphrase dialog gives up
LUKS_RAM_MIB=2560    # VM RAM needed to unlock LUKS2 (Argon2) key slots

# Dialog texts (edit to localize)
TXT_TITLE="Mount encrypted drive"
TXT_PROMPT="Enter the passphrase for the encrypted drive:"
TXT_RETRY="Mounting failed (wrong passphrase?). "
TXT_CANCEL="Cancel"
TXT_OK="Mount"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# Only one instance at a time
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK"' EXIT
touch "$HANDLED"

# Prints "<bsd name> <IOMedia id> <plain|luks>" for every Linux partition
# (GPT Linux filesystem, MBR 0x83, or GPT Linux LUKS).
linux_partitions() {
    ioreg -r -c IOMedia -w0 -l -d1 | awk -v gpt="$LINUX_GPT" -v luks="$LUKS_GPT" '
        /^\+-o/ { match($0, /id 0x[0-9a-f]+/); id = substr($0, RSTART + 3, RLENGTH - 3); content = ""; bsd = "" }
        /"Content" = /  { content = $NF; gsub(/"/, "", content) }
        /"BSD Name" = / { bsd = $NF; gsub(/"/, "", bsd) }
        bsd != "" && content != "" && id != "" {
            if (content == gpt || content == "0x83" || content == "Linux") print bsd, id, "plain"
            else if (content == luks) print bsd, id, "luks"
            id = ""
        }'
}

is_external() {
    diskutil info "$1" 2>/dev/null | grep -q "Device Location: *External"
}

is_mounted_by_anylinuxfs() {
    mount | grep -q "^${1}\.local:"
}

# Shows a passphrase dialog on the console user's screen.
# Prints the passphrase; exit status 0 = OK, 1 = cancelled / timed out.
ask_passphrase() {
    local uid="$1" dev="$2" name="$3" extra="$4" user
    user=$(id -un "$uid")
    launchctl asuser "$uid" sudo -u "$user" /usr/bin/osascript - \
        "$dev" "$name" "$extra" "$TXT_TITLE" "$TXT_PROMPT" "$TXT_CANCEL" "$TXT_OK" "$DIALOG_TIMEOUT" <<'EOF'
on run argv
    set {dev, diskName, extra, ttl, prompt, cancelTxt, okTxt, timeoutSec} to argv
    try
        set r to display dialog extra & prompt & return & diskName & " (/dev/" & dev & ")" ¬
            with title ttl default answer "" with hidden answer ¬
            buttons {cancelTxt, okTxt} default button okTxt cancel button cancelTxt ¬
            with icon caution giving up after (timeoutSec as integer)
        if gave up of r then error number -128
        return text returned of r
    on error number -128
        error "cancelled" number 1
    end try
end run
EOF
}

# Runs "anylinuxfs config" as the user who owns the anylinuxfs configuration.
alfs_config() {
    sudo -u "${SUDO_USER:?SUDO_USER must be set in the LaunchDaemon plist}" "$ANYLINUXFS" config "$@" >/dev/null
}

mount_plain() {
    local dev="$1"
    log "New Linux partition: /dev/$dev, mounting..."
    "$ANYLINUXFS" mount --ignore-permissions -w false "/dev/$dev"
    log "anylinuxfs /dev/$dev exit code: $?"
}

mount_luks() {
    local dev="$1" console_uid="$2" name extra="" try rc pass old_ram cfg
    name=$(diskutil info "${dev%s*}" 2>/dev/null | sed -n 's/^ *Device \/ Media Name: *//p')
    cfg="$HOME/.anylinuxfs/config.toml"
    log "New LUKS partition: /dev/$dev ($name), asking for passphrase..."

    for try in $(seq 1 "$MAX_TRIES"); do
        if ! pass=$(ask_passphrase "$console_uid" "$dev" "$name" "$extra"); then
            log "/dev/$dev: passphrase entry cancelled"
            return
        fi

        # When the passphrase comes from ALFS_PASSPHRASE, anylinuxfs does not raise the
        # VM's RAM for LUKS by itself, and unlocking fails with "Not enough available
        # memory to open a keyslot". Raise it for this mount only and restore it afterwards
        # (the setting is read when the VM starts, so restoring it right after is safe).
        old_ram=$(sed -n 's/^ram_size_mib *= *//p' "$cfg" 2>/dev/null)
        if [ -n "$old_ram" ] && [ "$old_ram" -lt "$LUKS_RAM_MIB" ]; then
            alfs_config -r "$LUKS_RAM_MIB"
        fi

        ALFS_PASSPHRASE="$pass" "$ANYLINUXFS" mount --ignore-permissions -w false "/dev/$dev"
        rc=$?
        unset pass

        if [ -n "$old_ram" ] && [ "$old_ram" -lt "$LUKS_RAM_MIB" ]; then
            alfs_config -r "$old_ram"
        fi

        log "anylinuxfs /dev/$dev exit code: $rc (attempt $try)"
        # anylinuxfs can exit 0 even when unlocking failed, so check the mount itself.
        is_mounted_by_anylinuxfs "$dev" && return
        extra="$TXT_RETRY"
    done
}

linux_partitions | while read -r dev id kind; do
    grep -qx "$id" "$HANDLED" && continue
    is_external "$dev" || continue

    if is_mounted_by_anylinuxfs "$dev"; then
        echo "$id" >> "$HANDLED"
        continue
    fi
    if mount | grep -q "^/dev/${dev} "; then
        echo "$id" >> "$HANDLED"
        log "/dev/$dev is already mounted by another driver (ExtendFS or similar?), skipping"
        continue
    fi

    if [ "$kind" = "plain" ]; then
        echo "$id" >> "$HANDLED"
        mount_plain "$dev"
        continue
    fi

    # LUKS needs a logged-in user to type the passphrase. If nobody is logged in, do not
    # mark it as handled, so it is retried after login.
    console_uid=$(stat -f %u /dev/console)
    [ "$console_uid" -eq 0 ] && continue
    echo "$id" >> "$HANDLED"
    mount_luks "$dev" "$console_uid"
done
