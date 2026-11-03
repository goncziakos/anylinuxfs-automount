# anylinuxfs-automount

Automatically mount external **ext2/3/4** and **LUKS-encrypted** Linux drives
**read-write** on macOS as soon as you plug them in, the way macOS mounts its own
disks.

macOS cannot write to Linux filesystems by itself.
[anylinuxfs](https://github.com/nohajc/anylinuxfs) solves that: it runs a small
Linux microVM that mounts the drive and shares it back to macOS over NFS. But
you have to start it by hand with `sudo anylinuxfs mount /dev/diskXsY` every
time. **anylinuxfs-automount** is a small LaunchDaemon that does it for you.

- Plain Linux partitions are mounted right away.
- For LUKS partitions, a native macOS dialog asks for the passphrase.
- The passphrase is never stored or logged.
- A drive you unmount by hand stays unmounted until you replug it.

<p align="center"><i>plug in → (passphrase dialog if encrypted) → drive appears in <code>/Volumes</code> and Finder</i></p>

---

## Requirements

- macOS on Apple Silicon (an anylinuxfs requirement). Developed on macOS 27 with anylinuxfs 0.20.1.
- [anylinuxfs](https://github.com/nohajc/anylinuxfs), installed and initialised:
  ```sh
  brew install nohajc/anylinuxfs/anylinuxfs
  anylinuxfs init
  ```
- Xcode Command Line Tools, to compile the launcher (`xcode-select --install`).
- Admin rights.

Before installing, check that a manual mount works: `sudo anylinuxfs mount /dev/diskXsY`
(find the identifier with `diskutil list`).

## Installation

```sh
git clone https://github.com/goncziakos/anylinuxfs-automount.git
cd anylinuxfs-automount
sudo ./install.sh
```

Then do the one step that can't be scripted:

1. **Grant Full Disk Access to the launcher.** The installer opens the right
   settings page.
   *System Settings → Privacy & Security → Full Disk Access → “+”*. Press
   <kbd>⌘</kbd><kbd>⇧</kbd><kbd>G</kbd>, enter `/usr/local/libexec/anylinuxfs-automount`, and
   turn the switch on.
2. Restart the daemon:
   ```sh
   sudo launchctl kickstart -k system/hu.goncziakos.anylinuxfs-automount
   ```

Running `install.sh` again upgrades an existing installation. It rebuilds the
launcher, so you have to grant Full Disk Access again (see
[Troubleshooting](#troubleshooting)).

## Usage

| What | How |
|---|---|
| Mount | Plug the drive in. It appears in `/Volumes/<label>` within ~5 seconds. |
| Encrypted drive | Type the passphrase in the dialog. You get 3 tries. *Cancel*, or 2 minutes without input, skips the drive until you replug it. |
| Unmount before unplugging | `anylinuxfs unmount` (all drives) or `anylinuxfs unmount /Volumes/<label>` |
| Mount again without replugging | `sudo anylinuxfs mount --ignore-permissions /dev/diskXsY` |
| See what happened | `tail -f /var/log/anylinuxfs-automount.log` and `anylinuxfs log` |
| Uninstall | `sudo ./uninstall.sh` |

> **Always unmount before unplugging.** Ejecting from Finder only removes the NFS share;
> `anylinuxfs unmount` also shuts the VM down cleanly and flushes the filesystem.

Files on mounted drives appear to be owned by you (`--ignore-permissions`), so
Finder can read and write everything without permission problems.

## How it works

```
launchd ──every 5 s──▶ /usr/local/libexec/anylinuxfs-automount      (tiny C binary, has Full Disk Access)
                         └─exec─▶ /usr/local/libexec/anylinuxfs-automount.sh
                                    ├─ ioreg: list partitions whose type is Linux / LUKS
                                    ├─ diskutil: keep only external ones
                                    ├─ skip ones already handled for this attachment
                                    ├─ LUKS: osascript dialog on the logged-in user's screen
                                    └─ anylinuxfs mount ──▶ microVM ──NFS──▶ /Volumes/<label>
```

**Partition detection.** The script reads the IORegistry (`ioreg -c IOMedia`) and
picks partitions with one of these types:

| Type | Meaning | Action |
|---|---|---|
| `0FC63DAF-8483-4772-8E79-3D69D8477DE4` | GPT *Linux filesystem* | mount |
| `0x83` / `Linux` | MBR Linux | mount |
| `CA7D7CCB-63ED-4C53-861C-1742536059CC` | GPT *Linux LUKS* | ask for the passphrase, then mount |

Only drives that `diskutil` reports as **External** are touched.

**Once per attachment.** Each partition's IORegistry object id is saved in
`/var/run/anylinuxfs-automount.handled`. The id changes on every replug, so:

- a replugged drive is mounted again;
- a drive you unmounted by hand is not mounted again behind your back;
- a dialog you cancelled does not keep coming back every 5 seconds.

`/var/run` is cleared on reboot.

**LUKS passphrase.** The daemon runs as root with no GUI. It uses
`launchctl asuser <console uid> … osascript` to show a `display dialog … with hidden answer`
on the logged-in user's screen. The passphrase reaches anylinuxfs only through the
`ALFS_PASSPHRASE` environment variable of that single process. If nobody is logged
in, the drive waits until someone logs in.

**Success check.** anylinuxfs can exit with status 0 even when unlocking failed. So
the script decides whether a mount succeeded by looking for `diskXsY.local:` in
`mount`, not by the exit code.

## Configuration

The tunables are at the top of `src/anylinuxfs-automount.sh`. After editing, run
`sudo ./install.sh` again.

| Variable | Default | Meaning |
|---|---|---|
| `MAX_TRIES` | `3` | Passphrase attempts per attachment |
| `DIALOG_TIMEOUT` | `120` | Seconds before the dialog gives up |
| `LUKS_RAM_MIB` | `2560` | VM RAM used while unlocking a LUKS drive |
| `TXT_*` | English | Dialog texts. Translate them to localize the dialog. |

The 5-second polling interval is `StartInterval` in `launchd/anylinuxfs-automount.plist.in`.
anylinuxfs's own settings (`anylinuxfs config`) still apply.

## Files

| Repository | Installed to |
|---|---|
| `src/launcher.c` | `/usr/local/libexec/anylinuxfs-automount` (compiled) |
| `src/anylinuxfs-automount.sh` | `/usr/local/libexec/anylinuxfs-automount.sh` |
| `launchd/anylinuxfs-automount.plist.in` | `/Library/LaunchDaemons/hu.goncziakos.anylinuxfs-automount.plist` |
| `install.sh`, `uninstall.sh` | – |

At runtime the tool also uses `/var/log/anylinuxfs-automount.log`,
`/var/run/anylinuxfs-automount.handled` and `/var/run/anylinuxfs-automount.lock`.

## Troubleshooting

**Log says `Operation not permitted` / `Insufficient permissions`, nothing mounts.**
The launcher lacks Full Disk Access. This also happens after every reinstall,
because a rebuilt binary counts as a new app. In the Full Disk Access list, remove
`anylinuxfs-automount` with “−”, add it again, and run
`sudo launchctl kickstart -k system/hu.goncziakos.anylinuxfs-automount`.

**`… is already mounted by another driver, skipping`.**
Another ext4 driver (for example a read-only FSKit extension such as ExtendFS)
mounted the drive first. Disable or uninstall it. The daemon cannot reliably
unmount drives mounted by such drivers.

**The passphrase dialog keeps asking even though the passphrase is right.**
Run `anylinuxfs log` and look for `Not enough available memory to open a keyslot`.
That means the VM needs more RAM for this LUKS drive's key slot. Raise
`LUKS_RAM_MIB` and reinstall. See also [Development notes](#development-notes).

**The drive is LUKS but no dialog appears.**
Check `diskutil list`. The partition type must be the GPT *Linux LUKS* GUID above.
A LUKS container in a partition typed as *Linux filesystem* is passed to anylinuxfs
without a passphrase, and anylinuxfs fails. Either change the partition type to
LUKS (`sgdisk -t N:8309`) or mount it by hand.

**Nothing at all happens.**
Run `sudo launchctl print system/hu.goncziakos.anylinuxfs-automount`. It shows
whether the daemon is loaded and its last exit status. Then check
`/var/log/anylinuxfs-automount.log`.

## Security notes

- The daemon runs as root and holds Full Disk Access, but the only program it starts
  is a fixed script in a root-owned directory. Keep `/usr/local/libexec` and its files
  owned by `root:wheel` and not writable by others (the installer sets this).
- LUKS passphrases live only in memory. They are passed to anylinuxfs through an
  environment variable, which only root can read for a root process.
- Mounted drives use `--ignore-permissions`, so any local user can read and write
  them. Leave that flag out in the script if that matters to you.

---

## Development notes

How the tool reached its current shape, problem by problem. Kept here because
each step explains a design decision that might otherwise look odd.

1. **Starting point.** A 6 TB ext4 external HDD that had to be writable on a Mac.
   anylinuxfs could do it, but only by hand with `sudo`. The goal was mounting on
   plug-in.

2. **Read-only FSKit driver in the way.** An FSKit-based ext4 extension (ExtendFS)
   was installed and mounted the drive read-only first. A root daemon could not
   unmount that mount reliably. Fix: uninstall the extension. The script now detects
   this case and logs it instead of fighting it.

3. **Polling LaunchDaemon instead of disk-arrival events.** launchd has no simple,
   reliable "external disk attached" trigger for daemons. A 5-second `StartInterval`
   polling an inexpensive `ioreg` query is simple and robust. A lock directory keeps
   runs from overlapping while a mount (or a dialog) is in progress.

4. **"Handle once" semantics.** Mounting every Linux partition that isn't mounted
   would immediately remount a drive the user had just unmounted on purpose.
   Remembering the IOMedia object id fixes that: the id is unique per attachment.

5. **TCC: `Operation not permitted`.** Run from launchd as root, anylinuxfs could not
   open `/dev/diskXsY`, even though the same command worked from Terminal (Terminal
   had Full Disk Access). Since macOS privacy protection also applies to root, the
   daemon itself needs Full Disk Access. A shell script can't usefully receive that
   grant, so a minimal C launcher (`src/launcher.c`) gets it and `exec`s the script.
   Child processes inherit the permission.

6. **anylinuxfs needs the user's context.** anylinuxfs keeps its VM image and
   configuration in `~/.anylinuxfs` and expects to run under `sudo`. The plist
   therefore sets `HOME`, `SUDO_USER`, `SUDO_UID` and `SUDO_GID` to the installing
   user.

7. **An SSD that was silently ignored.** A second drive never mounted and left no
   log entry. Its partition type was `CA7D7CCB-…`, *Linux LUKS*, which the type filter
   didn't include. A manual mount (which prompts for the passphrase) confirmed it was
   encrypted.

8. **Passphrase dialog from a root daemon.** Storing the passphrase on disk would
   defeat the encryption. Instead, `launchctl asuser` runs `osascript` inside the
   logged-in user's GUI session and shows a native hidden-input dialog. The answer is
   piped to anylinuxfs through `ALFS_PASSPHRASE`.

9. **"Wrong passphrase" with the right passphrase.** The dialog kept coming back.
   `anylinuxfs log` showed the real error:
   ```
   Linux: Not enough available memory to open a keyslot.
   Linux: Error: Failed to open encrypted device '/dev/vda': 3
   ```
   LUKS2 key slots use Argon2, which is memory-hard. The VM was configured with
   512 MiB. Kernel logs showed that interactive mounts had run with 2560 MiB:
   anylinuxfs raises the RAM by itself for LUKS when it prompts, but not when the
   passphrase comes from the environment variable. anylinuxfs also exited with
   status 0. Fixes:
   - raise `ram_size_mib` to 2560 just for the LUKS mount and restore it right
     after, so plain ext4 mounts keep their small VM;
   - judge success by the mount table instead of the exit code.

## License

[MIT](LICENSE)
