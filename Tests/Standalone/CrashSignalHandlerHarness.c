// Crashes child processes on purpose with the crash signal handler installed,
// checks each child still dies from its signal, and writes manifest.txt
// ("<scenario> <pid>" per line) so CrashReportRecoveryTests can read the
// records the children left behind.

#include "CrashSignalHandler.h"

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

__attribute__((noinline)) static void crash_level3(void) {
    volatile int *nowhere = NULL;
    *nowhere = 1;
}

__attribute__((noinline)) static void crash_level2(void) {
    crash_level3();
    __asm__ volatile("");
}

__attribute__((noinline)) static void crash_level1(void) {
    crash_level2();
    __asm__ volatile("");
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Winfinite-recursion"
__attribute__((noinline)) static int recurse_forever(int depth) {
    volatile char padding[256];
    padding[0] = (char)depth;
    return recurse_forever(depth + 1) + padding[0];
}
#pragma clang diagnostic pop

static void *crash_on_thread(void *unused) {
    (void)unused;
    crash_level1();
    return NULL;
}

static void run_scenario(const char *name) {
    if (strcmp(name, "segv") == 0) {
        crash_level1();
    } else if (strcmp(name, "abort") == 0) {
        abort();
    } else if (strcmp(name, "overflow") == 0) {
        recurse_forever(0);
    } else if (strcmp(name, "thread") == 0) {
        pthread_t thread;
        pthread_create(&thread, NULL, crash_on_thread, NULL);
        pthread_join(thread, NULL);
    } else if (strcmp(name, "note") == 0) {
        fv_crash_handler_write_note("Uncaught exception Test: line one\nline two");
        abort();
    }
    // "clean" and anything unknown fall through to a normal exit.
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <records directory>\n", argv[0]);
        return 2;
    }
    const char *directory = argv[1];
    static const struct {
        const char *name;
        int signal; // 0 = expect a normal exit
    } scenarios[] = {
        { "segv", SIGSEGV },
        { "abort", SIGABRT },
        { "overflow", -1 }, // SIGSEGV or SIGBUS, depending on where the guard page sits
        { "thread", SIGSEGV },
        { "note", SIGABRT },
        { "clean", 0 },
    };

    char manifestPath[1024];
    snprintf(manifestPath, sizeof(manifestPath), "%s/manifest.txt", directory);
    FILE *manifest = fopen(manifestPath, "w");
    if (manifest == NULL) {
        perror("manifest");
        return 1;
    }

    int failures = 0;
    for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); i++) {
        fflush(NULL);
        pid_t pid = fork();
        if (pid == 0) {
            char recordPath[1024];
            snprintf(recordPath, sizeof(recordPath), "%s/crash-pending-%d.txt", directory, getpid());
            if (!fv_crash_handler_install(recordPath, "app harness (1)\nos test\n")) {
                _exit(3);
            }
            fv_crash_handler_install_alt_stack();
            run_scenario(scenarios[i].name);
            _exit(0);
        }
        int status = 0;
        waitpid(pid, &status, 0);
        int expected = scenarios[i].signal;
        int ok;
        if (expected == 0) {
            ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
        } else if (expected < 0) {
            ok = WIFSIGNALED(status) && (WTERMSIG(status) == SIGSEGV || WTERMSIG(status) == SIGBUS);
        } else {
            ok = WIFSIGNALED(status) && WTERMSIG(status) == expected;
        }
        if (!ok) {
            fprintf(stderr, "FAIL %s: child status %d, expected signal %d\n", scenarios[i].name, status, expected);
            failures++;
        }
        fprintf(manifest, "%s %d\n", scenarios[i].name, pid);
    }
    fclose(manifest);
    return failures == 0 ? 0 : 1;
}
