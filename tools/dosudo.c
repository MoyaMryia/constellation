/* dosudo -- minimal setuid helper behind /usr/bin/sudo.
 *
 * The 770ED image has no PAM and musl's crypt() is a stub, so a "real" sudo
 * with user-password verification is not practical. Instead this follows the
 * doas model: a small setuid-root binary that checks the caller against a
 * one-line-per-user rule file and then execs the command as root.
 *
 *   /etc/constellation/sudoers   (root:root 0640)
 *       # users allowed to run commands as root
 *       moyamryia
 *
 * Build with the project toolchain (static, i486):
 *   i486-linux-musl-gcc -m32 -march=i486 -Os -static -o dosudo tools/dosudo.c
 * Installed by build-rootfs-770ed.sh as /usr/libexec/dosudo (root:root 4755).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>
#include <errno.h>

#define RULES "/etc/constellation/sudoers"

static int allowed(const char *user)
{
    FILE *f = fopen(RULES, "r");
    char line[256];
    int ok = 0;

    if (!f)
        return 0;
    while (fgets(line, sizeof(line), f)) {
        char *p = line, *end;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\n' || *p == '\0')
            continue;
        end = strpbrk(p, " \t\r\n");
        if (end)
            *end = '\0';
        if (strcmp(p, user) == 0) {
            ok = 1;
            break;
        }
    }
    fclose(f);
    return ok;
}

int main(int argc, char **argv)
{
    struct passwd *pw;
    uid_t ruid = getuid();

    if (ruid == 0) {                    /* already root: just exec */
        if (argc < 2) {
            fprintf(stderr, "usage: sudo command [args...]\n");
            return 1;
        }
        if (strcmp(argv[1], "-s") == 0)
            execl("/bin/sh", "sh", "-i", (char *)NULL);
        execvp(argv[1], &argv[1]);
        perror("sudo: exec");
        return 126;
    }

    pw = getpwuid(ruid);
    if (!pw) {
        fprintf(stderr, "sudo: unknown uid %u\n", (unsigned)ruid);
        return 1;
    }
    if (!allowed(pw->pw_name)) {
        fprintf(stderr, "sudo: %s is not listed in %s\n", pw->pw_name, RULES);
        return 1;
    }
    if (argc < 2) {
        fprintf(stderr, "usage: sudo command [args...]   (or: sudo -s)\n");
        return 1;
    }

    setgroups(0, NULL);
    if (setgid(0) != 0 || setuid(0) != 0) {
        perror("sudo: cannot become root");
        return 1;
    }
    if (strcmp(argv[1], "-s") == 0)
        execl("/bin/sh", "sh", "-i", (char *)NULL);
    execvp(argv[1], &argv[1]);
    perror("sudo: exec");
    return 126;
}
