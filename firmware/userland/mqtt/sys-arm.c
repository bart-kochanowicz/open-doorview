/* Freestanding ARM EABI Linux layer for the camera (no libc). */
#include "sys.h"

#define NR_exit 1
#define NR_read 3
#define NR_write 4
#define NR_open 5
#define NR_close 6
#define NR_poll 168
#define NR_clock_gettime 263
#define NR_socket 281
#define NR_connect 283
#define NR_getsockopt 295

#define O_RDONLY 0
#define O_WRONLY 1
#define O_NONBLOCK 04000
#define O_CLOEXEC 02000000

static long call(long number, long a, long b, long c)
{
    register long r0 __asm__("r0") = a;
    register long r1 __asm__("r1") = b;
    register long r2 __asm__("r2") = c;
    register long r7 __asm__("r7") = number;
    __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r7) : "memory", "cc");
    return r0;
}

/* The compiler may emit these even with -ffreestanding. */
void *memcpy(void *destination, const void *source, unsigned long length)
{
    u8 *to = destination;
    const u8 *from = source;
    while (length--)
        *to++ = *from++;
    return destination;
}

void *memset(void *destination, int value, unsigned long length)
{
    u8 *to = destination;
    while (length--)
        *to++ = (u8)value;
    return destination;
}

int sys_open_read(const char *path, int nonblock)
{
    return (int)call(NR_open, (long)path, O_RDONLY | O_CLOEXEC | (nonblock ? O_NONBLOCK : 0), 0);
}

int sys_open_write(const char *path)
{
    return (int)call(NR_open, (long)path, O_WRONLY | O_CLOEXEC, 0);
}

int sys_read(int fd, void *buf, int length)
{
    return (int)call(NR_read, fd, (long)buf, length);
}

int sys_write(int fd, const void *buf, int length)
{
    return (int)call(NR_write, fd, (long)buf, length);
}

void sys_close(int fd)
{
    call(NR_close, fd, 0, 0);
}

struct sockaddr_in_raw {
    u16 family;
    u8 port[2];
    u8 address[4];
    u8 zero[8];
};

struct pollfd_raw {
    int fd;
    short events;
    short revents;
};

int sys_tcp_start(u32 address, u16 port)
{
    struct sockaddr_in_raw peer;
    int fd = (int)call(NR_socket, 2 /* AF_INET */, 1 /* SOCK_STREAM */ | O_NONBLOCK | O_CLOEXEC, 0);
    long result;

    if (fd < 0)
        return fd;
    memset(&peer, 0, sizeof(peer));
    peer.family = 2;
    peer.port[0] = (u8)(port >> 8);
    peer.port[1] = (u8)port;
    peer.address[0] = (u8)(address >> 24);
    peer.address[1] = (u8)(address >> 16);
    peer.address[2] = (u8)(address >> 8);
    peer.address[3] = (u8)address;
    result = call(NR_connect, fd, (long)&peer, sizeof(peer));
    if (result < 0 && result != -115 /* EINPROGRESS */) {
        sys_close(fd);
        return (int)result;
    }
    return fd;
}

int sys_tcp_status(int fd)
{
    struct pollfd_raw entry = { fd, 4 /* POLLOUT */, 0 };
    int error = 0;
    int size = sizeof(error);

    if (call(NR_poll, (long)&entry, 1, 0) <= 0)
        return 1;
    {
        register long r0 __asm__("r0") = fd;
        register long r1 __asm__("r1") = 1; /* SOL_SOCKET */
        register long r2 __asm__("r2") = 4; /* SO_ERROR */
        register long r3 __asm__("r3") = (long)&error;
        register long r4 __asm__("r4") = (long)&size;
        register long r7 __asm__("r7") = NR_getsockopt;
        __asm__ volatile("svc 0" : "+r"(r0) : "r"(r1), "r"(r2), "r"(r3), "r"(r4), "r"(r7) : "memory", "cc");
        if (r0 < 0)
            return (int)r0;
    }
    return error ? -error : 0;
}

void sys_wait(int kmsg_fd, int socket_fd, int socket_wants_write, int timeout_ms)
{
    struct pollfd_raw entries[2];
    int count = 0;

    if (kmsg_fd >= 0) {
        entries[count].fd = kmsg_fd;
        entries[count].events = 1; /* POLLIN */
        entries[count].revents = 0;
        count++;
    }
    if (socket_fd >= 0) {
        entries[count].fd = socket_fd;
        entries[count].events = (short)(1 | (socket_wants_write ? 4 : 0));
        entries[count].revents = 0;
        count++;
    }
    call(NR_poll, (long)entries, count, timeout_ms);
}

u32 sys_now_ms(void)
{
    long now[2];

    call(NR_clock_gettime, 1 /* CLOCK_MONOTONIC */, (long)now, 0);
    return (u32)now[0] * 1000u + (u32)now[1] / 1000000u;
}

void sys_exit(int code)
{
    call(NR_exit, code, 0, 0);
    for (;;) {
    }
}

int app_main(const char *config_path);

void start_c(int argc, char **argv)
{
    sys_exit(app_main(argc > 1 ? argv[1] : "/etc/doorview/mqtt.conf"));
}

/* The kernel enters with sp pointing at argc, then argv[]. */
__asm__(".arm\n"
        ".global _start\n"
        "_start:\n"
        "    ldr r0, [sp]\n"
        "    add r1, sp, #4\n"
        "    bic sp, sp, #7\n"
        "    bl start_c\n");
