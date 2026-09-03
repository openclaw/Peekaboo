#include "DescriptorForkTestSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

DescriptorForkProbeResult peekaboo_probe_descriptor_after_fork(int descriptor) {
    struct stat original;
    if (fcntl(descriptor, F_GETFD) < 0 || fstat(descriptor, &original) < 0) {
        return DescriptorForkProbeInputError;
    }

    pid_t child = fork();
    if (child < 0) {
        return DescriptorForkProbeForkError;
    }
    if (child == 0) {
        // Never return to Swift or unlock the shared flock: only async-signal-safe child operations.
        if (fcntl(descriptor, F_GETFD) < 0) {
            _exit(errno == EBADF ? DescriptorForkProbeClosed : DescriptorForkProbeChildError);
        }
        struct stat inherited;
        if (fstat(descriptor, &inherited) < 0 ||
            inherited.st_dev != original.st_dev || inherited.st_ino != original.st_ino) {
            _exit(DescriptorForkProbeChildError);
        }
        _exit(DescriptorForkProbeInherited);
    }

    int child_status;
    pid_t waited;
    do {
        waited = waitpid(child, &child_status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != child) {
        return DescriptorForkProbeWaitError;
    }

    struct stat parent;
    if (fcntl(descriptor, F_GETFD) < 0 || fstat(descriptor, &parent) < 0 ||
        parent.st_dev != original.st_dev || parent.st_ino != original.st_ino) {
        return DescriptorForkProbeParentChanged;
    }
    if (!WIFEXITED(child_status)) {
        return DescriptorForkProbeUnexpectedExit;
    }
    switch (WEXITSTATUS(child_status)) {
        case DescriptorForkProbeClosed:
            return DescriptorForkProbeClosed;
        case DescriptorForkProbeInherited:
            return DescriptorForkProbeInherited;
        case DescriptorForkProbeChildError:
            return DescriptorForkProbeChildError;
        default:
            return DescriptorForkProbeUnexpectedExit;
    }
}
