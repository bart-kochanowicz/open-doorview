#ifndef DOORVIEW_SYS_H
#define DOORVIEW_SYS_H

/* Thin platform layer. sys-arm.c uses raw Linux syscalls (no libc) for the camera;
 * sys-host.c uses POSIX so the same logic can be tested against a real broker. */

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;

#define SYS_EAGAIN (-11)
#define SYS_EPIPE (-32)

int sys_open_read(const char *path, int nonblock); /* fd or < 0 */
int sys_open_write(const char *path);              /* fd or < 0 */
int sys_read(int fd, void *buf, int length);       /* bytes, 0 at EOF, SYS_EAGAIN, < 0 on error */
int sys_write(int fd, const void *buf, int length);
void sys_close(int fd);

/* Starts a non-blocking TCP connection. Returns an fd or < 0. */
int sys_tcp_start(u32 address_host_order, u16 port);
/* 0 = connected, 1 = still connecting, < 0 = failed. */
int sys_tcp_status(int fd);

/* Sleeps until the kernel-log fd or the socket may be ready, or the timeout passes. Either fd may be -1. */
void sys_wait(int kmsg_fd, int socket_fd, int socket_wants_write, int timeout_ms);
u32 sys_now_ms(void);
void sys_exit(int code);
/* Writes the filesystems out. */
void sys_sync(void);
/* Writes the filesystems out and restarts the machine; does not return (the host build exits with 86 instead). */
void sys_reboot(void);

#endif
