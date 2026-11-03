/*
 * anylinuxfs-automount launcher
 *
 * A tiny compiled wrapper that just execs the automount shell script.
 *
 * Why it exists: macOS privacy protection (TCC) blocks a root LaunchDaemon from
 * reading raw removable disks ("Operation not permitted" / "Insufficient
 * permissions") unless the daemon's own executable has Full Disk Access.
 * You cannot grant Full Disk Access to a shell script in a useful way (it would
 * have to go to /bin/bash for every caller), so this binary is what gets the
 * grant. Processes it starts (bash, anylinuxfs, diskutil, ...) inherit it,
 * because the launcher counts as the "responsible process".
 *
 * Every time this binary is rebuilt, Full Disk Access has to be granted again.
 */
#include <stdio.h>
#include <unistd.h>

#ifndef SCRIPT_PATH
#define SCRIPT_PATH "/usr/local/libexec/anylinuxfs-automount.sh"
#endif

int main(void)
{
    char *const argv[] = { "/bin/bash", SCRIPT_PATH, NULL };
    execv("/bin/bash", argv);
    perror("anylinuxfs-automount: execv /bin/bash");
    return 1;
}
