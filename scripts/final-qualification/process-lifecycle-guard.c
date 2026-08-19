#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define MAX_WATCHED_PIDS 1024

static uint64_t wall_milliseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_REALTIME, &value) != 0) return 0;
    return ((uint64_t)value.tv_sec * 1000ULL) + ((uint64_t)value.tv_nsec / 1000000ULL);
}

static void fail(const char *message) {
    fprintf(stderr, "process-lifecycle-guard: %s\n", message);
    exit(2);
}

static int parse_pid(const char *text) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value <= 0 || value > INT32_MAX) {
        fail("PID is invalid");
    }
    return (int)value;
}

static int open_temporary(const char *path, char temporary[PATH_MAX]) {
    int length = snprintf(temporary, PATH_MAX, "%s.tmp.%d", path, getpid());
    if (length <= 0 || length >= PATH_MAX) fail("private output path is too long");
    int descriptor = open(
        temporary,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0600);
    if (descriptor < 0) fail("cannot create private output");
    return descriptor;
}

static void finish_file(int descriptor, const char *temporary, const char *path) {
    if (fsync(descriptor) != 0 || close(descriptor) != 0) fail("cannot commit private output");
    if (renamex_np(temporary, path, RENAME_EXCL) != 0) {
        unlink(temporary);
        fail("cannot publish private output exclusively");
    }
}

static void publish_ready(const char *path, pid_t owner, uint64_t started) {
    char temporary[PATH_MAX];
    int descriptor = open_temporary(path, temporary);
    if (dprintf(
            descriptor,
            "{\n  \"version\": 1,\n  \"pid\": %d,\n  \"started_at_milliseconds\": %llu\n}\n",
            owner,
            (unsigned long long)started) < 0) {
        fail("cannot write readiness receipt");
    }
    finish_file(descriptor, temporary, path);
}

static void publish_result(
    const char *path,
    const pid_t *pids,
    size_t pid_count,
    uint64_t started,
    bool passed,
    pid_t event_pid,
    uint32_t event_flags
) {
    char temporary[PATH_MAX];
    int descriptor = open_temporary(path, temporary);
    if (dprintf(
            descriptor,
            "{\n  \"version\": 1,\n  \"passed\": %s,\n"
            "  \"started_at_milliseconds\": %llu,\n"
            "  \"completed_at_milliseconds\": %llu,\n"
            "  \"watched_pids\": [",
            passed ? "true" : "false",
            (unsigned long long)started,
            (unsigned long long)wall_milliseconds()) < 0) {
        fail("cannot write lifecycle result");
    }
    for (size_t index = 0; index < pid_count; index++) {
        if (dprintf(descriptor, "%s%d", index == 0 ? "" : ", ", pids[index]) < 0) {
            fail("cannot write watched PID list");
        }
    }
    if (dprintf(
            descriptor,
            "],\n  \"event_count\": %d,\n  \"event_pid\": %s,\n"
            "  \"event_flags\": %s\n}\n",
            passed ? 0 : 1,
            passed ? "null" : "0",
            passed ? "null" : "0") < 0) {
        fail("cannot finish lifecycle result");
    }
    if (!passed) {
        off_t end = lseek(descriptor, 0, SEEK_END);
        if (end < 0 || ftruncate(descriptor, 0) != 0 || lseek(descriptor, 0, SEEK_SET) < 0) {
            fail("cannot rewrite lifecycle violation");
        }
        if (dprintf(
                descriptor,
                "{\n  \"version\": 1,\n  \"passed\": false,\n"
                "  \"started_at_milliseconds\": %llu,\n"
                "  \"completed_at_milliseconds\": %llu,\n"
                "  \"watched_pids\": [",
                (unsigned long long)started,
                (unsigned long long)wall_milliseconds()) < 0) {
            fail("cannot write lifecycle violation");
        }
        for (size_t index = 0; index < pid_count; index++) {
            if (dprintf(descriptor, "%s%d", index == 0 ? "" : ", ", pids[index]) < 0) {
                fail("cannot write violation PID list");
            }
        }
        if (dprintf(
                descriptor,
                "],\n  \"event_count\": 1,\n  \"event_pid\": %d,\n"
                "  \"event_flags\": %u\n}\n",
                event_pid,
                event_flags) < 0) {
            fail("cannot finish lifecycle violation");
        }
    }
    finish_file(descriptor, temporary, path);
}

static bool stop_requested(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) return false;
    if (!S_ISREG(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0077) != 0) {
        fail("stop marker is not one owner-private regular file");
    }
    return true;
}

static bool authorization_requested(const char *path) {
    struct stat info;
    if (lstat(path, &info) != 0) {
        if (errno == ENOENT) return false;
        fail("cannot inspect authorization request");
    }
    if (!S_ISREG(info.st_mode) || info.st_uid != geteuid() || (info.st_mode & 0077) != 0
        || info.st_nlink != 1) {
        fail("authorization request is not one owner-private regular file");
    }
    return true;
}

static bool publish_authorization(
    const char *source,
    const char *destination,
    const char *result_path,
    const char *stop_path
) {
    struct stat source_info;
    if (lstat(source, &source_info) != 0 || !S_ISREG(source_info.st_mode)
        || source_info.st_uid != geteuid() || (source_info.st_mode & 0077) != 0
        || source_info.st_nlink != 1) {
        fail("staged authorization is not one owner-private regular file");
    }
    struct stat destination_info;
    if (lstat(destination, &destination_info) == 0 || errno != ENOENT) {
        fail("authorization destination already exists or is inaccessible");
    }
    uint64_t authorized_at = wall_milliseconds();
    char temporary[PATH_MAX];
    int descriptor = open_temporary(result_path, temporary);
    if (dprintf(
            descriptor,
            "{\n  \"version\": 1,\n  \"guard_pid\": %d,\n"
            "  \"authorized_at_milliseconds\": %llu\n}\n",
            getpid(),
            (unsigned long long)authorized_at) < 0) {
        fail("cannot write authorization result");
    }
    finish_file(descriptor, temporary, result_path);
    if (stop_requested(stop_path)) return false;
    if (renamex_np(source, destination, RENAME_EXCL) != 0) {
        fail("cannot publish authorization exclusively");
    }
    return true;
}

static int self_test(void) {
    int queue = kqueue();
    if (queue < 0) fail("self-test kqueue failed");
    struct kevent change;
    EV_SET(&change, (uintptr_t)getpid(), EVFILT_PROC, EV_ADD | EV_CLEAR, NOTE_FORK, 0, NULL);
    if (kevent(queue, &change, 1, NULL, 0, NULL) != 0) fail("self-test registration failed");
    pid_t child = fork();
    if (child < 0) fail("self-test fork failed");
    if (child == 0) _exit(0);
    struct kevent event;
    struct timespec timeout = { .tv_sec = 2, .tv_nsec = 0 };
    int count = kevent(queue, NULL, 0, &event, 1, &timeout);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
    close(queue);
    if (count != 1 || event.ident != (uintptr_t)getpid() || (event.fflags & NOTE_FORK) == 0) {
        fail("self-test did not observe fork");
    }
    printf("{\"version\":1,\"passed\":true}\n");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return self_test();
    const char *ready_path = NULL;
    const char *stop_path = NULL;
    const char *output_path = NULL;
    const char *authorization_request_path = NULL;
    const char *authorization_source_path = NULL;
    const char *authorization_destination_path = NULL;
    const char *authorization_result_path = NULL;
    pid_t pids[MAX_WATCHED_PIDS];
    size_t pid_count = 0;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--pid") == 0) {
            if (++index >= argc || pid_count >= MAX_WATCHED_PIDS) fail("PID list is invalid");
            pids[pid_count++] = (pid_t)parse_pid(argv[index]);
        } else {
            if (index + 1 >= argc) fail("option has no value");
            if (strcmp(argv[index], "--ready") == 0) ready_path = argv[++index];
            else if (strcmp(argv[index], "--stop") == 0) stop_path = argv[++index];
            else if (strcmp(argv[index], "--output") == 0) output_path = argv[++index];
            else if (strcmp(argv[index], "--authorization-request") == 0) {
                authorization_request_path = argv[++index];
            } else if (strcmp(argv[index], "--authorization-source") == 0) {
                authorization_source_path = argv[++index];
            } else if (strcmp(argv[index], "--authorization-destination") == 0) {
                authorization_destination_path = argv[++index];
            } else if (strcmp(argv[index], "--authorization-result") == 0) {
                authorization_result_path = argv[++index];
            }
            else fail("unknown option");
        }
    }
    if (!ready_path || !stop_path || !output_path || pid_count == 0) {
        fail("closed lifecycle request is incomplete");
    }
    bool authorization_enabled = authorization_request_path && authorization_source_path
        && authorization_destination_path && authorization_result_path;
    if (!authorization_enabled && (authorization_request_path || authorization_source_path
        || authorization_destination_path || authorization_result_path)) {
        fail("authorization publication request is incomplete");
    }
    for (size_t left = 0; left < pid_count; left++) {
        for (size_t right = left + 1; right < pid_count; right++) {
            if (pids[left] == pids[right]) fail("PID list contains duplicates");
        }
    }
    pid_t original_parent = getppid();
    int queue = kqueue();
    if (queue < 0) fail("kqueue failed");
    struct kevent *changes = calloc(pid_count, sizeof(struct kevent));
    if (!changes) fail("cannot allocate process watchers");
    for (size_t index = 0; index < pid_count; index++) {
        EV_SET(
            &changes[index],
            (uintptr_t)pids[index],
            EVFILT_PROC,
            EV_ADD | EV_CLEAR,
            NOTE_FORK | NOTE_EXEC | NOTE_EXIT,
            0,
            NULL);
    }
    if (kevent(queue, changes, (int)pid_count, NULL, 0, NULL) != 0) {
        fail("cannot register process lifecycle watchers");
    }
    free(changes);
    uint64_t started = wall_milliseconds();
    publish_ready(ready_path, getpid(), started);
    bool authorization_published = false;
    while (true) {
        if (getppid() != original_parent) {
            publish_result(output_path, pids, pid_count, started, false, original_parent, NOTE_EXIT);
            return 3;
        }
        bool stopping = stop_requested(stop_path);
        struct kevent event;
        struct timespec timeout = {
            .tv_sec = 0,
            .tv_nsec = stopping ? 0 : 10000000,
        };
        int count = kevent(queue, NULL, 0, &event, 1, &timeout);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) fail("lifecycle wait failed");
        if (count == 1) {
            publish_result(
                output_path,
                pids,
                pid_count,
                started,
                false,
                (pid_t)event.ident,
                event.fflags);
            return 3;
        }
        if (!stopping && authorization_enabled && !authorization_published
            && authorization_requested(authorization_request_path)) {
            struct timespec immediate = { .tv_sec = 0, .tv_nsec = 0 };
            count = kevent(queue, NULL, 0, &event, 1, &immediate);
            if (count < 0 && errno == EINTR) continue;
            if (count < 0) fail("authorization lifecycle drain failed");
            if (count == 1) {
                publish_result(
                    output_path,
                    pids,
                    pid_count,
                    started,
                    false,
                    (pid_t)event.ident,
                    event.fflags);
                return 3;
            }
            if (getppid() != original_parent) {
                publish_result(output_path, pids, pid_count, started, false, original_parent, NOTE_EXIT);
                return 3;
            }
            authorization_published = publish_authorization(
                authorization_source_path,
                authorization_destination_path,
                authorization_result_path,
                stop_path);
            if (!authorization_published) continue;
        }
        if (stopping) {
            publish_result(output_path, pids, pid_count, started, true, 0, 0);
            return 0;
        }
    }
}
