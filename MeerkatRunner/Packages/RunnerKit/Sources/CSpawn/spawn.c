#include "CSpawn.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

int csp_openpty(int *primary, int *secondary, unsigned short cols, unsigned short rows) {
    if (primary == NULL || secondary == NULL) {
        return EINVAL;
    }
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (openpty(primary, secondary, NULL, NULL, &size) != 0) {
        return errno;
    }
    int flags = fcntl(*primary, F_GETFL);
    if (flags == -1 || fcntl(*primary, F_SETFL, flags | O_NONBLOCK) == -1
        || fcntl(*primary, F_SETFD, FD_CLOEXEC) == -1 || fcntl(*secondary, F_SETFD, FD_CLOEXEC) == -1) {
        int error = errno;
        close(*primary);
        close(*secondary);
        return error;
    }
    return 0;
}

int csp_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd, int secondary, pid_t *pid) {
    if (path == NULL || argv == NULL || envp == NULL || cwd == NULL || pid == NULL || secondary < 0) {
        return EINVAL;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    int error = posix_spawn_file_actions_init(&actions);
    if (error != 0) {
        return error;
    }
    error = posix_spawnattr_init(&attr);
    if (error != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return error;
    }

    for (int fd = 0; fd <= 2 && error == 0; fd++) {
        error = posix_spawn_file_actions_adddup2(&actions, secondary, fd);
    }
    if (error == 0) {
        error = posix_spawn_file_actions_addchdir_np(&actions, cwd);
    }

    sigset_t none;
    sigset_t all;
    sigemptyset(&none);
    sigfillset(&all);
    if (error == 0) {
        error = posix_spawnattr_setsigmask(&attr, &none);
    }
    if (error == 0) {
        error = posix_spawnattr_setsigdefault(&attr, &all);
    }
    if (error == 0) {
        short flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
        error = posix_spawnattr_setflags(&attr, flags);
    }
    if (error == 0) {
        error = posix_spawn(pid, path, &actions, &attr, argv, envp);
    }

    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&actions);
    return error;
}

int csp_reap(pid_t pid, int *exit_code) {
    int status = 0;
    pid_t result = waitpid(pid, &status, WNOHANG);
    if (result == 0) {
        return 0;
    }
    if (result < 0) {
        return -1;
    }
    if (exit_code != NULL) {
        if (WIFEXITED(status)) {
            *exit_code = WEXITSTATUS(status);
        } else if (WIFSIGNALED(status)) {
            *exit_code = 128 + WTERMSIG(status);
        } else {
            *exit_code = -1;
        }
    }
    return 1;
}
