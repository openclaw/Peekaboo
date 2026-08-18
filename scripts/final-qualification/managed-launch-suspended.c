#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

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

static int parse_positive(const char *text, int minimum, int maximum) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < minimum || value > maximum) {
        fail("numeric option is invalid");
    }
    return (int)value;
}

static void write_pid_file(const char *path, pid_t child) {
    int descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) fail("cannot create child PID file");
    char bytes[96];
    int length = snprintf(bytes, sizeof(bytes), "{\n  \"version\": 1,\n  \"pid\": %d\n}\n", child);
    if (length <= 0 || write(descriptor, bytes, (size_t)length) != length || fsync(descriptor) != 0) {
        close(descriptor);
        fail("cannot commit child PID file");
    }
    close(descriptor);
}

static bool private_ack_exists(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) return false;
    if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || (info.st_mode & 0077) != 0 ||
        info.st_uid != geteuid()) {
        fail("start acknowledgement is not one owner-private regular file");
    }
    return true;
}

int main(int argc, char **argv) {
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

    pid_t original_parent = getppid();
    uint64_t started = now_milliseconds();
    write_pid_file(pid_path, child);
    printf("SPAWNED %d %llu\n", child, (unsigned long long)started);
    fflush(stdout);

    uint64_t start_deadline = started + ((uint64_t)start_timeout_seconds * 1000ULL);
    while (!private_ack_exists(ack_path)) {
        if (getppid() != original_parent || now_milliseconds() >= start_deadline) {
            kill(child, SIGKILL);
            waitpid(child, NULL, 0);
            fail("identity acknowledgement timed out or launcher exited");
        }
        sleep_milliseconds(10);
    }
    if (kill(child, SIGCONT) != 0) {
        kill(child, SIGKILL);
        waitpid(child, NULL, 0);
        fail("cannot release authenticated child");
    }
    printf("RELEASED %d\n", child);
    fflush(stdout);

    uint64_t run_deadline = now_milliseconds() + ((uint64_t)run_timeout_seconds * 1000ULL);
    int wait_status = 0;
    bool sent_term = false;
    uint64_t kill_deadline = 0;
    while (true) {
        pid_t result = waitpid(child, &wait_status, WNOHANG);
        if (result == child) break;
        if (result < 0) fail("waitpid failed");
        uint64_t now = now_milliseconds();
        if (getppid() != original_parent) {
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
    printf(
        "EXIT %d %d %d %llu\n",
        child,
        exit_code,
        signal_number,
        (unsigned long long)completed);
    fflush(stdout);
    return 0;
}
