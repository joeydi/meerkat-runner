// CSpawn: the raw posix_spawn + openpty calls behind ProcessSupervisor (AGENTS.md §6.2).
//
// SECURITY (§8.1 rule 2): only the Supervisor target depends on this module, and only
// ProcessSupervisor.spawn (behind @_spi(ApprovalGate)) calls csp_spawn. Grep for csp_spawn to audit.

#ifndef CSPAWN_H
#define CSPAWN_H

#include <sys/types.h>

/// Opens a PTY pair sized cols×rows. The primary is non-blocking; both are close-on-exec.
/// Returns 0, or an errno value.
int csp_openpty(int *primary, int *secondary, unsigned short cols, unsigned short rows);

/// Spawns `path` with `argv` / `envp` (NULL-terminated) in a new session (POSIX_SPAWN_SETSID, so its
/// PGID is its PID), with `secondary` as fds 0–2, `cwd` as its working directory, default signal
/// handlers, an empty signal mask, and no other inherited fds (POSIX_SPAWN_CLOEXEC_DEFAULT).
/// Returns 0 and sets *pid, or an errno value.
int csp_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd, int secondary, pid_t *pid);

/// waitpid(pid, WNOHANG). Returns 1 and sets *exit_code (exit status, or 128 + signal) once reaped,
/// 0 if still running, -1 on error.
int csp_reap(pid_t pid, int *exit_code);

#endif /* CSPAWN_H */
