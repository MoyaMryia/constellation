/* dopower -- direct reboot(2) helper used by /sbin/{poweroff,reboot,halt}.
 *
 * Why not busybox: our /bin/busybox is setuid root (needed for su/sudo through
 * FEATURE_SUID). busybox's SUID machinery then re-checks every applet against
 * /etc/busybox.conf, which we do not ship -- and `poweroff` silently did
 * nothing. This binary is not setuid, has no config, and just calls
 * reboot(2): poweroff / reboot / halt.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/reboot.h>

int main(int argc, char **argv)
{
    int how = RB_POWER_OFF;
    const char *what = "poweroff";

    if (argc > 1) {
        if (strcmp(argv[1], "reboot") == 0)      { how = RB_AUTOBOOT;     what = "reboot"; }
        else if (strcmp(argv[1], "halt") == 0)   { how = RB_HALT_SYSTEM;  what = "halt"; }
        else if (strcmp(argv[1], "poweroff") == 0) { how = RB_POWER_OFF;  what = "poweroff"; }
        else {
            fprintf(stderr, "usage: dopower [poweroff|reboot|halt]\n");
            return 2;
        }
    }
    sync();
    printf("dopower: %s\n", what);
    fflush(stdout);
    reboot(how);
    perror("dopower: reboot");
    return 1;
}
