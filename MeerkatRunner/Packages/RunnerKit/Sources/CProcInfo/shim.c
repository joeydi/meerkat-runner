#include "CProcInfo.h"

#include <errno.h>

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
