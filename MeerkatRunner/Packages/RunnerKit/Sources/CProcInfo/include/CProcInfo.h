// CProcInfo: the only place RunnerKit touches libproc / sysctl headers directly.
// Keep this shim thin: plain C wrappers with explicit buffer sizes. Swift-facing
// API lives in the ProcInfo module. See AGENTS.md §4.

#ifndef CPROCINFO_H
#define CPROCINFO_H

#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>
#include <sys/types.h>

/// Size of the buffer needed for KERN_PROCARGS2 (`kern.argmax`), or -1 on error.
int cpi_argmax(void);

/// Reads KERN_PROCARGS2 for `pid` into `buffer` (capacity `size`).
/// Returns the number of bytes written, or -1 with errno set (EPERM, ESRCH, ...).
int cpi_procargs2(pid_t pid, char *buffer, size_t size);

#endif /* CPROCINFO_H */
