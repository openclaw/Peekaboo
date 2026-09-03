#ifndef DESCRIPTOR_FORK_TEST_SUPPORT_H
#define DESCRIPTOR_FORK_TEST_SUPPORT_H

typedef enum DescriptorForkProbeResult {
    DescriptorForkProbeClosed,
    DescriptorForkProbeInherited,
    DescriptorForkProbeInputError,
    DescriptorForkProbeForkError,
    DescriptorForkProbeWaitError,
    DescriptorForkProbeChildError,
    DescriptorForkProbeUnexpectedExit,
    DescriptorForkProbeParentChanged
} DescriptorForkProbeResult;

// Validates a live descriptor, forks/reaps entirely in C, and checks the parent still owns the same inode.
DescriptorForkProbeResult peekaboo_probe_descriptor_after_fork(int descriptor);

#endif
