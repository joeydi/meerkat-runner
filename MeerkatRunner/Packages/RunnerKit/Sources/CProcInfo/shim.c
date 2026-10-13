#include "CProcInfo.h"

#include <arpa/inet.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(CPI_PATH_MAX >= PROC_PIDPATHINFO_MAXSIZE, "CPI_PATH_MAX too small for proc_pidpath");

/// Copies at most `max` bytes of a possibly unterminated C string into `dst` (capacity `cap`).
static void cpi_copy_bounded(char *dst, size_t cap, const char *src, size_t max) {
    size_t n = strnlen(src, max);
    if (n >= cap) {
        n = cap - 1;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

int cpi_pid_count_hint(uid_t uid) {
    int bytes = proc_listpids(PROC_UID_ONLY, uid, NULL, 0);
    if (bytes <= 0) {
        return -1;
    }
    return bytes / (int)sizeof(pid_t);
}

int cpi_list_pids(uid_t uid, pid_t *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        errno = EINVAL;
        return -1;
    }
    int bytes = proc_listpids(PROC_UID_ONLY, uid, buffer, capacity * (int)sizeof(pid_t));
    if (bytes <= 0) {
        return -1;
    }
    return bytes / (int)sizeof(pid_t);
}

int cpi_list_pgrp_pids(pid_t pgid, pid_t *buffer, int capacity) {
    if (buffer == NULL || capacity <= 0) {
        errno = EINVAL;
        return -1;
    }
    int bytes = proc_listpids(PROC_PGRP_ONLY, (uint32_t)pgid, buffer, capacity * (int)sizeof(pid_t));
    if (bytes < 0) {
        return -1;
    }
    return bytes / (int)sizeof(pid_t);
}

int cpi_bsd_info(pid_t pid, cpi_bsdinfo *out) {
    if (out == NULL) {
        errno = EINVAL;
        return -1;
    }
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, (int)sizeof(info));
    if (size <= 0) {
        return -1;
    }
    if (size < (int)sizeof(info)) {
        errno = EIO;
        return -1;
    }
    memset(out, 0, sizeof(*out));
    out->pid = (int32_t)info.pbi_pid;
    out->ppid = (int32_t)info.pbi_ppid;
    out->pgid = (int32_t)info.pbi_pgid;
    out->uid = (uint32_t)info.pbi_uid;
    out->start_sec = info.pbi_start_tvsec;
    out->start_usec = info.pbi_start_tvusec;
    if (info.pbi_name[0] != '\0') {
        cpi_copy_bounded(out->name, sizeof(out->name), info.pbi_name, sizeof(info.pbi_name));
    } else {
        cpi_copy_bounded(out->name, sizeof(out->name), info.pbi_comm, sizeof(info.pbi_comm));
    }
    return 0;
}

int cpi_listen_sockets(pid_t pid, cpi_listen_socket *out, int capacity) {
    if (out == NULL || capacity <= 0) {
        errno = EINVAL;
        return -1;
    }
    int needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (needed <= 0) {
        return -1;
    }
    // Headroom for fds opened between the two calls.
    int slots = needed / (int)sizeof(struct proc_fdinfo) + 32;
    struct proc_fdinfo *fds = calloc((size_t)slots, sizeof(struct proc_fdinfo));
    if (fds == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, slots * (int)sizeof(struct proc_fdinfo));
    if (used <= 0) {
        free(fds);
        return -1;
    }

    int count = used / (int)sizeof(struct proc_fdinfo);
    int found = 0;
    for (int i = 0; i < count && found < capacity; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }
        struct socket_fdinfo si;
        int size = proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, (int)sizeof(si));
        if (size < (int)sizeof(si)) {
            continue;
        }
        if (si.psi.soi_kind != SOCKINFO_TCP) {
            continue;
        }
        const struct tcp_sockinfo *tcp = &si.psi.soi_proto.pri_tcp;
        if (tcp->tcpsi_state != TSI_S_LISTEN) {
            continue;
        }
        const struct in_sockinfo *ini = &tcp->tcpsi_ini;
        cpi_listen_socket *entry = &out[found++];
        memset(entry, 0, sizeof(*entry));
        entry->port = (int32_t)ntohs((uint16_t)ini->insi_lport);
        if (ini->insi_vflag & INI_IPV6) {
            entry->is_ipv6 = 1;
            memcpy(entry->addr, &ini->insi_laddr.ina_6, 16);
        } else {
            memcpy(entry->addr, &ini->insi_laddr.ina_46.i46a_addr4, 4);
        }
    }
    free(fds);
    return found;
}

int cpi_pidpath(pid_t pid, char *buffer, size_t size) {
    if (buffer == NULL || size < PROC_PIDPATHINFO_MAXSIZE) {
        errno = EINVAL;
        return -1;
    }
    int length = proc_pidpath(pid, buffer, (uint32_t)size);
    if (length <= 0) {
        return -1;
    }
    buffer[length < (int)size ? length : (int)size - 1] = '\0';
    return length;
}

int cpi_cwd(pid_t pid, char *buffer, size_t size) {
    if (buffer == NULL || size == 0) {
        errno = EINVAL;
        return -1;
    }
    struct proc_vnodepathinfo vpi;
    int got = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, (int)sizeof(vpi));
    if (got < (int)sizeof(vpi)) {
        if (got > 0) {
            errno = EIO;
        }
        return -1;
    }
    const char *path = vpi.pvi_cdir.vip_path;
    size_t length = strnlen(path, sizeof(vpi.pvi_cdir.vip_path));
    if (length == 0) {
        errno = ENOENT;
        return -1;
    }
    if (length >= size) {
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(buffer, path, length);
    buffer[length] = '\0';
    return (int)length;
}

int cpi_argmax(void) {
    int mib[2] = { CTL_KERN, KERN_ARGMAX };
    int argmax = 0;
    size_t size = sizeof(argmax);
    if (sysctl(mib, 2, &argmax, &size, NULL, 0) != 0) {
        return -1;
    }
    return argmax;
}

int cpi_procargs2(pid_t pid, char *buffer, size_t size) {
    if (buffer == NULL || size == 0) {
        errno = EINVAL;
        return -1;
    }
    int mib[3] = { CTL_KERN, KERN_PROCARGS2, pid };
    size_t length = size;
    if (sysctl(mib, 3, buffer, &length, NULL, 0) != 0) {
        return -1;
    }
    return (int)length;
}
