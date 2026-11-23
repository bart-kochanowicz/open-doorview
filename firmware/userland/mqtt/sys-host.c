/* POSIX layer used only to test the daemon logic against a real broker on a development host. */
#include "sys.h"

#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int app_main(const char *config_path);

int sys_open_read(const char *path, int nonblock)
{
    int fd = open(path, O_RDONLY | (nonblock ? O_NONBLOCK : 0));

    return fd < 0 ? -errno : fd;
}

int sys_open_write(const char *path)
{
    int fd = open(path, O_WRONLY);

    return fd < 0 ? -errno : fd;
}

int sys_read(int fd, void *buf, int length)
{
    ssize_t count = read(fd, buf, (size_t)length);

    if (count < 0)
        return errno == EAGAIN ? SYS_EAGAIN : -errno;
    return (int)count;
}

int sys_write(int fd, const void *buf, int length)
{
    ssize_t count = write(fd, buf, (size_t)length);

    if (count < 0)
        return errno == EAGAIN ? SYS_EAGAIN : -errno;
    return (int)count;
}

void sys_close(int fd)
{
    close(fd);
}

int sys_tcp_start(u32 address, u16 port)
{
    struct sockaddr_in peer = { 0 };
    int fd = socket(AF_INET, SOCK_STREAM, 0);

    if (fd < 0)
        return -errno;
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    peer.sin_family = AF_INET;
    peer.sin_port = htons(port);
    peer.sin_addr.s_addr = htonl(address);
    if (connect(fd, (struct sockaddr *)&peer, sizeof(peer)) < 0 && errno != EINPROGRESS) {
        int error = errno;

        close(fd);
        return -error;
    }
    return fd;
}

int sys_tcp_status(int fd)
{
    struct pollfd entry = { fd, POLLOUT, 0 };
    int error = 0;
    socklen_t size = sizeof(error);

    if (poll(&entry, 1, 0) <= 0)
        return 1;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0)
        return -errno;
    return error ? -error : 0;
}

void sys_wait(int kmsg_fd, int socket_fd, int socket_wants_write, int timeout_ms)
{
    struct pollfd entries[1];
    int slice = timeout_ms < 50 ? timeout_ms : 50;

    /* A regular file (the test's fake kernel log) is always "readable", so poll only the socket. */
    (void)kmsg_fd;
    if (socket_fd >= 0) {
        entries[0].fd = socket_fd;
        entries[0].events = (short)(POLLIN | (socket_wants_write ? POLLOUT : 0));
        entries[0].revents = 0;
        poll(entries, 1, slice);
    } else {
        struct timespec pause = { 0, slice * 1000000L };

        nanosleep(&pause, 0);
    }
}

u32 sys_now_ms(void)
{
    struct timespec now;

    clock_gettime(CLOCK_MONOTONIC, &now);
    return (u32)now.tv_sec * 1000u + (u32)now.tv_nsec / 1000000u;
}

void sys_exit(int code)
{
    _exit(code);
}

void sys_sync(void)
{
    sync();
}

void sys_reboot(void)
{
    _exit(86);
}

int main(int argc, char **argv)
{
    signal(SIGPIPE, SIG_IGN); /* a closed socket must return an error, as on the camera */
    return app_main(argc > 1 ? argv[1] : "/etc/doorview/mqtt.conf");
}
