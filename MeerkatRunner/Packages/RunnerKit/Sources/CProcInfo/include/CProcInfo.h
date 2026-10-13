// CProcInfo: the only place RunnerKit touches libproc / sysctl headers directly.
// Keep this shim thin: plain C wrappers that copy what Runner needs into small, fixed-size
// structs, with explicit buffer sizes. Swift-facing API lives in the ProcInfo module.
// See AGENTS.md §4.
//
// Every function returns -1 with errno set on failure (EPERM / ESRCH are expected for
// processes that are protected or exit mid-scan; callers skip them silently).

#ifndef CPROCINFO_H
#define CPROCINFO_H

#include <libproc.h>
#include <stdint.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>

/// Buffer size for `cpi_pidpath` / `cpi_cwd` (>= PROC_PIDPATHINFO_MAXSIZE).
enum { CPI_PATH_MAX = 4096 };

/// Subset of `struct proc_bsdinfo`.
typedef struct cpi_bsdinfo {
    int32_t pid;
    int32_t ppid;
    int32_t pgid;
    uint32_t uid;
    uint64_t start_sec;
    uint64_t start_usec;
    /// NUL-terminated; `pbi_name`, falling back to `pbi_comm`.
    char name[64];
} cpi_bsdinfo;

/// A TCP socket in LISTEN state.
typedef struct cpi_listen_socket {
    /// Host byte order.
    int32_t port;
    int32_t is_ipv6;
    /// 4 bytes (IPv4) or 16 bytes (IPv6), network order.
    uint8_t addr[16];
} cpi_listen_socket;

/// Upper bound on the number of PIDs owned by `uid`, or -1.
int cpi_pid_count_hint(uid_t uid);

/// Fills `buffer` with PIDs owned by `uid` (`proc_listpids(PROC_UID_ONLY, …)`). Returns the count, or -1.
int cpi_list_pids(uid_t uid, pid_t *buffer, int capacity);

/// Fills `buffer` with PIDs in process group `pgid` (`proc_listpids(PROC_PGRP_ONLY, …)`). Returns the count, or -1.
int cpi_list_pgrp_pids(pid_t pgid, pid_t *buffer, int capacity);

/// `proc_pidinfo(PROC_PIDTBSDINFO)`. Returns 0, or -1.
int cpi_bsd_info(pid_t pid, cpi_bsdinfo *out);

/// Walks `PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`, keeping TCP sockets in `TSI_S_LISTEN`.
/// Returns the number written to `out` (at most `capacity`), or -1.
int cpi_listen_sockets(pid_t pid, cpi_listen_socket *out, int capacity);

/// `proc_pidpath`. Writes a NUL-terminated path; returns its length, or -1.
int cpi_pidpath(pid_t pid, char *buffer, size_t size);

/// `PROC_PIDVNODEPATHINFO` → `pvi_cdir.vip_path`. Writes a NUL-terminated path; returns its length, or -1.
int cpi_cwd(pid_t pid, char *buffer, size_t size);

/// Size of the buffer needed for KERN_PROCARGS2 (`kern.argmax`), or -1 on error.
int cpi_argmax(void);

/// Reads KERN_PROCARGS2 for `pid` into `buffer` (capacity `size`).
/// Returns the number of bytes written, or -1 with errno set (EPERM, ESRCH, ...).
int cpi_procargs2(pid_t pid, char *buffer, size_t size);

#endif /* CPROCINFO_H */
