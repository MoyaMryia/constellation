/* 致命信号探针：定位 SIGILL 落在哪个共享库（Xorg 自己只打一个地址）。 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <signal.h>

static void which_map(pid_t pid, unsigned long addr)
{
    char path[64], line[512];
    FILE *f;
    unsigned long lo, hi;
    char perms[8], pathname[256];
    int off, maj, min;
    unsigned long inode;
    snprintf(path, sizeof path, "/proc/%d/maps", pid);
    f = fopen(path, "r");
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        pathname[0] = 0;
        if (sscanf(line, "%lx-%lx %7s %x %x:%x %lu %255s",
                   &lo, &hi, perms, &off, &maj, &min, &inode, pathname) < 7)
            continue;
        if (addr >= lo && addr < hi) {
            printf("IN %s %s off=0x%x file=%s\n", pathname[0] ? pathname : "[anon]",
                   perms, off + (int)(addr - lo), pathname);
            break;
        }
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    pid_t pid;
    int status;
    if (argc < 2) { fprintf(stderr, "usage: probe prog [args]\n"); return 2; }
    pid = fork();
    if (pid == 0) {
        ptrace(PTRACE_TRACEME, 0, 0, 0);
        execv(argv[1], &argv[1]);
        _exit(127);
    }
    waitpid(pid, &status, 0);
    while (WIFSTOPPED(status)) {
        int sig = WSTOPSIG(status);
        siginfo_t si;
        memset(&si, 0, sizeof si);
        ptrace(PTRACE_GETSIGINFO, pid, 0, &si);
        if (sig == SIGILL || sig == SIGSEGV || sig == SIGBUS || sig == SIGFPE) {
            printf("[probe] %s at %p\n", strsignal(sig), si.si_addr);
            which_map(pid, (unsigned long)si.si_addr);
            break;
        }
        ptrace(PTRACE_CONT, pid, 0, 0);
        waitpid(pid, &status, 0);
    }
    return 0;
}
