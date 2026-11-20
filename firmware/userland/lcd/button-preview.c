#include <asm/unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <sys/file.h>
#include <sys/wait.h>

static long call(long number, long a, long b, long c, long d)
{
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    register long r3 __asm__("r3") = d;
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r7) : "memory", "cc");
    return r0;
}

#define LOG(message) call(__NR_write, 1, (long)(message), sizeof(message) - 1, 0)

static int is_button_message(const char *record, long length, unsigned long long *timestamp)
{
    static const char message[] = "doorview_control: command=a5 length=8\n";
    long index = 0;
    for (int field = 0; field < 2; ++field) {
        while (index < length && record[index] != ',')
            ++index;
        if (index == length)
            return 0;
        ++index;
    }
    unsigned long long stamp = 0;
    long start = index;
    while (index < length && record[index] >= '0' && record[index] <= '9') {
        stamp = stamp * 10 + (unsigned)(record[index] - '0');
        ++index;
    }
    if (index == start || index == length || record[index] != ',')
        return 0;
    while (index < length && record[index] != ';')
        ++index;
    if (index == length || length - ++index != sizeof(message) - 1)
        return 0;
    for (size_t position = 0; position < sizeof(message) - 1; ++position) {
        if (record[index + position] != message[position])
            return 0;
    }
    *timestamp = stamp;
    return 1;
}

static long start_preview(void)
{
    long pid = call(__NR_fork, 0, 0, 0, 0);
    if (pid == 0) {
        static char *const args[] = {"sh", "/tmp/lcd-vo-test/live-30.sh", NULL};
        static char *const env[] = {"PATH=/usr/sbin:/usr/bin:/sbin:/bin", NULL};
        long log = call(__NR_open, (long)"/tmp/lcd-vo-test/button-preview-last.log",
                        O_WRONLY | O_CREAT | O_TRUNC, 0600, 0);
        if (log >= 0) {
            call(__NR_dup2, log, 1, 0, 0);
            call(__NR_dup2, log, 2, 0, 0);
            call(__NR_close, log, 0, 0, 0);
            call(__NR_execve, (long)"/bin/sh", (long)args, (long)env, 0);
        }
        call(__NR_exit, 1, 0, 0, 0);
        __builtin_unreachable();
    }
    return pid;
}

static int watch(void)
{
    long lock = call(__NR_open, (long)"/tmp/lcd-vo-test/button-preview.lock",
                     O_CREAT | O_RDWR | O_CLOEXEC, 0600, 0);
    if (lock < 0 || call(__NR_flock, lock, LOCK_EX | LOCK_NB, 0, 0) < 0) {
        LOG("Button preview lock unavailable\n");
        return 1;
    }
    long log = call(__NR_open, (long)"/dev/kmsg", O_RDONLY | O_CLOEXEC, 0, 0);
    if (log < 0 || call(__NR_lseek, log, 0, 2, 0) < 0) {
        LOG("Cannot follow MCU events\n");
        return 1;
    }
    LOG("BUTTON_PREVIEW_READY\n");
    long preview = 0;
    unsigned long long previous = 0;
    char record[4096];
    for (;;) {
        long count = call(__NR_read, log, (long)record, sizeof(record), 0);
        if (count == -EINTR || count == -EPIPE)
            continue;
        if (count <= 0)
            return 1;
        if (preview > 0) {
            int status = 0;
            if (call(__NR_wait4, preview, (long)&status, WNOHANG, 0) == preview) {
                if (status == 0)
                    LOG("BUTTON_PREVIEW_FINISHED\n");
                else
                    LOG("BUTTON_PREVIEW_FAILED\n");
                preview = 0;
            }
        }
        unsigned long long timestamp;
        if (!is_button_message(record, count, &timestamp))
            continue;
        int duplicate = previous && timestamp - previous < 250000;
        previous = timestamp;
        if (duplicate || preview > 0)
            continue;
        preview = start_preview();
        if (preview > 0)
            LOG("BUTTON_PREVIEW_STARTED\n");
        else
            LOG("BUTTON_PREVIEW_FORK_FAILED\n");
    }
}

void _start(void)
{
    call(__NR_exit, watch(), 0, 0, 0);
    __builtin_unreachable();
}
