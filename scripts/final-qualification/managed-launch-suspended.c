#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <mach/message.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/proc_info.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

struct pbq_proc_uniqidentifierinfo {
    uint8_t executable_uuid[16];
    uint64_t unique_id;
    uint64_t parent_unique_id;
    int32_t pid_version;
    int32_t original_parent_pid_version;
    uint64_t reserved2;
    uint64_t reserved3;
};

#define PBQ_PROC_PIDUNIQIDENTIFIERINFO 17

static uint64_t now_milliseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_REALTIME, &value) != 0) return 0;
    return ((uint64_t)value.tv_sec * 1000ULL) + ((uint64_t)value.tv_nsec / 1000000ULL);
}

static void sleep_milliseconds(unsigned value) {
    struct timespec interval = {
        .tv_sec = (time_t)(value / 1000),
        .tv_nsec = (long)(value % 1000) * 1000000L,
    };
    while (nanosleep(&interval, &interval) != 0 && errno == EINTR) {}
}

static void fail(const char *message) {
    fprintf(stderr, "managed-launch-suspended: %s\n", message);
    exit(2);
}

static volatile sig_atomic_t termination_requested = 0;

static void request_termination(int signal_number) {
    (void)signal_number;
    termination_requested = 1;
}

static void terminate_and_reap(pid_t child) {
    if (child <= 0) return;
    if (kill(child, SIGKILL) != 0 && errno != ESRCH) {
        fprintf(stderr, "managed-launch-suspended: cannot kill owned child\n");
    }
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

static void fail_with_child(const char *message, pid_t child) {
    terminate_and_reap(child);
    fail(message);
}

static int parse_positive(const char *text, int minimum, int maximum) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < minimum || value > maximum) {
        fail("numeric option is invalid");
    }
    return (int)value;
}

static uint64_t parse_u64(const char *text) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0) {
        fail("process generation is invalid");
    }
    return (uint64_t)value;
}

static bool exact_process_identity(
    pid_t pid,
    uint64_t *start_identity,
    int32_t *pid_version,
    uint64_t *unique_id
) {
    struct pbq_proc_uniqidentifierinfo first;
    struct pbq_proc_uniqidentifierinfo second;
    struct proc_bsdinfo bsd;
    int unique_size = (int)sizeof(first);
    int bsd_size = (int)sizeof(bsd);
    if (proc_pidinfo(pid, PBQ_PROC_PIDUNIQIDENTIFIERINFO, 0, &first, unique_size) != unique_size) {
        return false;
    }
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsd_size) != bsd_size) return false;
    if (proc_pidinfo(pid, PBQ_PROC_PIDUNIQIDENTIFIERINFO, 0, &second, unique_size) != unique_size) {
        return false;
    }
    if (first.pid_version != second.pid_version || first.unique_id != second.unique_id ||
        bsd.pbi_pid != (uint32_t)pid) {
        fail("process generation changed during cleanup identity acquisition");
    }
    *start_identity = (bsd.pbi_start_tvsec * 1000000ULL) + bsd.pbi_start_tvusec;
    *pid_version = first.pid_version;
    *unique_id = first.unique_id;
    return true;
}

static int terminate_exact_process(const char *pid_text, const char *start_text) {
    pid_t pid = (pid_t)parse_positive(pid_text, 1, INT32_MAX);
    uint64_t expected_start = parse_u64(start_text);
    uint64_t observed_start = 0;
    uint64_t unique_id = 0;
    int32_t pid_version = 0;
    if (!exact_process_identity(pid, &observed_start, &pid_version, &unique_id)) {
        if (kill(pid, 0) == 0 || errno != ESRCH) fail("cannot authenticate a live cleanup process");
        printf("{\"version\":1,\"pid\":%d,\"start_identity\":\"%s\",\"terminated\":false,\"absent\":true}\n",
            pid, start_text);
        return 0;
    }
    if (observed_start != expected_start) fail("cleanup process generation does not match");
    audit_token_t token = { .val = { 0, 0, 0, 0, 0, (uint32_t)pid, 0, (uint32_t)pid_version } };
    if (proc_signal_with_audittoken(&token, SIGKILL) != 0) {
        if (errno == ESRCH) {
            printf("{\"version\":1,\"pid\":%d,\"start_identity\":\"%s\",\"terminated\":false,\"absent\":true}\n",
                pid, start_text);
            return 0;
        }
        fail("generation-safe cleanup signal failed");
    }
    for (int attempt = 0; attempt < 200; attempt++) {
        uint64_t current_start = 0;
        uint64_t current_unique_id = 0;
        int32_t current_pid_version = 0;
        if (!exact_process_identity(pid, &current_start, &current_pid_version, &current_unique_id) ||
            current_pid_version != pid_version || current_unique_id != unique_id) {
            printf("{\"version\":1,\"pid\":%d,\"start_identity\":\"%s\",\"terminated\":true,\"absent\":false}\n",
                pid, start_text);
            return 0;
        }
        sleep_milliseconds(10);
    }
    fail("generation-safe cleanup process did not terminate");
    return 2;
}

static bool write_pid_file(const char *path, pid_t child) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) return false;
    char bytes[96];
    int length = snprintf(bytes, sizeof(bytes), "{\n  \"version\": 1,\n  \"pid\": %d\n}\n", child);
    if (length <= 0 || write(descriptor, bytes, (size_t)length) != length || fsync(descriptor) != 0) {
        close(descriptor);
        return false;
    }
    close(descriptor);
    return true;
}

static bool private_ack_exists(const char *path, pid_t child) {
    struct stat info;
    if (lstat(path, &info) != 0) return false;
    if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || (info.st_mode & 0077) != 0 ||
        info.st_uid != geteuid()) {
        fail_with_child("start acknowledgement is not one owner-private regular file", child);
    }
    return true;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "--terminate-exact") == 0) {
        return terminate_exact_process(argv[2], argv[3]);
    }
    const char *stdout_path = NULL;
    const char *stderr_path = NULL;
    const char *pid_path = NULL;
    const char *ack_path = NULL;
    int start_timeout_seconds = 0;
    int run_timeout_seconds = 0;
    int separator = -1;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--") == 0) {
            separator = index;
            break;
        }
        if (index + 1 >= argc) fail("option has no value");
        if (strcmp(argv[index], "--stdout") == 0) stdout_path = argv[++index];
        else if (strcmp(argv[index], "--stderr") == 0) stderr_path = argv[++index];
        else if (strcmp(argv[index], "--pid-file") == 0) pid_path = argv[++index];
        else if (strcmp(argv[index], "--ack-file") == 0) ack_path = argv[++index];
        else if (strcmp(argv[index], "--start-timeout") == 0) {
            start_timeout_seconds = parse_positive(argv[++index], 5, 120);
        } else if (strcmp(argv[index], "--run-timeout") == 0) {
            run_timeout_seconds = parse_positive(argv[++index], 5, 7200);
        } else fail("unknown option");
    }
    if (!stdout_path || !stderr_path || !pid_path || !ack_path || start_timeout_seconds == 0 ||
        run_timeout_seconds == 0 || separator < 0 || separator + 1 >= argc) {
        fail("closed launch request is incomplete");
    }
    pid_t original_parent = getppid();
    if (signal(SIGTERM, request_termination) == SIG_ERR ||
        signal(SIGINT, request_termination) == SIG_ERR ||
        signal(SIGHUP, request_termination) == SIG_ERR ||
        signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        fail("cannot install guardian signal handlers");
    }
    if (termination_requested) fail("termination requested before suspended spawn");

    int stdout_descriptor = open(
        stdout_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    int stderr_descriptor = open(
        stderr_path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (stdout_descriptor < 0 || stderr_descriptor < 0) fail("cannot create child output files");

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions) != 0 || posix_spawnattr_init(&attributes) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, stdout_descriptor, STDOUT_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, stderr_descriptor, STDERR_FILENO) != 0 ||
        posix_spawn_file_actions_addclose(&actions, stdout_descriptor) != 0 ||
        posix_spawn_file_actions_addclose(&actions, stderr_descriptor) != 0 ||
        posix_spawnattr_setflags(&attributes, POSIX_SPAWN_START_SUSPENDED) != 0) {
        fail("cannot initialize suspended spawn");
    }

    pid_t child = 0;
    char **child_argv = &argv[separator + 1];
    int spawn_error = posix_spawn(
        &child, child_argv[0], &actions, &attributes, child_argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(stdout_descriptor);
    close(stderr_descriptor);
    if (spawn_error != 0 || child <= 0) fail("suspended child spawn failed");
    if (termination_requested || getppid() != original_parent) {
        fail_with_child("termination requested or launcher exited during suspended spawn", child);
    }
    uint64_t started = now_milliseconds();
    if (!write_pid_file(pid_path, child)) fail_with_child("cannot commit child PID file", child);
    if (printf("SPAWNED %d %llu\n", child, (unsigned long long)started) < 0 ||
        fflush(stdout) != 0) {
        fail_with_child("cannot publish suspended child identity", child);
    }

    uint64_t start_deadline = started + ((uint64_t)start_timeout_seconds * 1000ULL);
    while (!private_ack_exists(ack_path, child)) {
        if (termination_requested || getppid() != original_parent ||
            now_milliseconds() >= start_deadline) {
            fail_with_child("identity acknowledgement timed out or launcher exited", child);
        }
        sleep_milliseconds(10);
    }
    if (kill(child, SIGCONT) != 0) {
        fail_with_child("cannot release authenticated child", child);
    }
    if (printf("RELEASED %d\n", child) < 0 || fflush(stdout) != 0) {
        fail_with_child("cannot publish authenticated child release", child);
    }

    uint64_t run_deadline = now_milliseconds() + ((uint64_t)run_timeout_seconds * 1000ULL);
    int wait_status = 0;
    bool sent_term = false;
    uint64_t kill_deadline = 0;
    while (true) {
        pid_t result = waitpid(child, &wait_status, WNOHANG);
        if (result == child) break;
        if (result < 0) fail_with_child("waitpid failed", child);
        uint64_t now = now_milliseconds();
        if (termination_requested || getppid() != original_parent) {
            kill(child, SIGKILL);
            waitpid(child, &wait_status, 0);
            break;
        }
        if (!sent_term && now >= run_deadline) {
            kill(child, SIGTERM);
            sent_term = true;
            kill_deadline = now + 2000;
        } else if (sent_term && now >= kill_deadline) {
            kill(child, SIGKILL);
        }
        sleep_milliseconds(25);
    }

    uint64_t completed = now_milliseconds();
    int exit_code = WIFEXITED(wait_status) ? WEXITSTATUS(wait_status) : -1;
    int signal_number = WIFSIGNALED(wait_status) ? WTERMSIG(wait_status) : 0;
    if (printf(
        "EXIT %d %d %d %llu\n",
        child,
        exit_code,
        signal_number,
        (unsigned long long)completed) < 0 || fflush(stdout) != 0) {
        fail("cannot publish child exit status");
    }
    return 0;
}
