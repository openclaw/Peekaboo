#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

static void terminate_child(pid_t process_identifier) {
    int child_status = 0;
    (void)kill(process_identifier, SIGKILL);
    while (waitpid(process_identifier, &child_status, 0) < 0 && errno == EINTR) {
    }
}

int main(int argument_count, char *arguments[]) {
    if (argument_count < 2 || setsid() < 0) {
        return 120;
    }
    const char *detached_terminal = getenv("PEEKABOO_TEST_DETACHED_TTY");
    if (detached_terminal != NULL && strcmp(detached_terminal, "1") == 0) {
        if (dprintf(STDOUT_FILENO, "PEEKABOO_CHILD_PID=%d\n", getpid()) < 0) {
            return 121;
        }
        execv(arguments[1], &arguments[1]);
        return 122;
    }
    if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) != 0) {
        return 123;
    }

    int release_pipe[2] = {-1, -1};
    if (pipe(release_pipe) != 0 ||
        fcntl(release_pipe[0], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(release_pipe[1], F_SETFD, FD_CLOEXEC) != 0) {
        return 124;
    }

    pid_t process_identifier = fork();
    if (process_identifier < 0) {
        return 125;
    }
    if (process_identifier == 0) {
        close(release_pipe[1]);
        const int prompt_signals[] = {
            SIGALRM, SIGHUP, SIGINT, SIGPIPE, SIGQUIT, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU,
        };
        for (size_t index = 0; index < sizeof(prompt_signals) / sizeof(prompt_signals[0]); index++) {
            (void)signal(prompt_signals[index], SIG_DFL);
        }
        sigset_t empty_signal_mask;
        sigemptyset(&empty_signal_mask);
        (void)sigprocmask(SIG_SETMASK, &empty_signal_mask, NULL);
        char release_byte = 0;
        ssize_t read_result;
        do {
            read_result = read(release_pipe[0], &release_byte, 1);
        } while (read_result < 0 && errno == EINTR);
        close(release_pipe[0]);
        if (read_result != 1) {
            _exit(127);
        }
        execv(arguments[1], &arguments[1]);
        _exit(128);
    }

    close(release_pipe[0]);
    const char *background_terminal = getenv("PEEKABOO_TEST_BACKGROUND_TTY");
    pid_t foreground_process_group =
        background_terminal != NULL && strcmp(background_terminal, "1") == 0
            ? getpgrp()
            : process_identifier;
    // Only the parent assigns the group: concurrent setpgid calls can fail with EPERM on Darwin.
    // The release pipe keeps the child from execing until group and terminal setup is complete.
    if (setpgid(process_identifier, process_identifier) != 0 ||
        signal(SIGTTOU, SIG_IGN) == SIG_ERR ||
        tcsetpgrp(STDIN_FILENO, foreground_process_group) != 0 ||
        dprintf(STDOUT_FILENO, "PEEKABOO_CHILD_PID=%d\n", process_identifier) < 0 ||
        write(release_pipe[1], "x", 1) != 1) {
        close(release_pipe[1]);
        terminate_child(process_identifier);
        return 129;
    }
    close(release_pipe[1]);

    int child_status = 0;
    pid_t wait_result;
    for (;;) {
        wait_result = waitpid(process_identifier, &child_status, WUNTRACED);
        if (wait_result < 0 && errno == EINTR) {
            continue;
        }
        if (wait_result == process_identifier && WIFSTOPPED(child_status)) {
            // Resume only after the parent has consumed the completed stop event.
            if (dprintf(STDOUT_FILENO, "PEEKABOO_CHILD_STOPPED=%d:%d\n",
                        process_identifier, WSTOPSIG(child_status)) < 0) {
                terminate_child(process_identifier);
                return 132;
            }
            continue;
        }
        break;
    }
    (void)tcsetpgrp(STDIN_FILENO, getpgrp());
    if (wait_result != process_identifier) {
        return 130;
    }
    if (WIFEXITED(child_status)) {
        return WEXITSTATUS(child_status);
    }
    if (WIFSIGNALED(child_status)) {
        int signal_number = WTERMSIG(child_status);
        sigset_t signal_mask;
        sigemptyset(&signal_mask);
        sigaddset(&signal_mask, signal_number);
        (void)sigprocmask(SIG_UNBLOCK, &signal_mask, NULL);
        (void)signal(signal_number, SIG_DFL);
        (void)kill(getpid(), signal_number);
        return 128 + signal_number;
    }
    return 131;
}
