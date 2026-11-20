#!/usr/bin/env python3
"""Read-only copy of /dev/mtdblock5 (rootfs_data overlay) over UART, handling a logged-in or logged-out console."""
import base64, gzip, hashlib, os, re, select, sys, termios, time, tty

port = os.environ.get('DOORVIEW_UART') or sys.exit('Set DOORVIEW_UART to the serial device (for example /dev/ttyUSB0 or /dev/cu.usbserial-XXXX)')
out = sys.argv[1]
password = sys.stdin.buffer.readline().rstrip(b'\r\n')
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
tty.setraw(fd)
raw_attrs = termios.tcgetattr(fd)
raw_attrs[4] = raw_attrs[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, raw_attrs)
command = (b"stty -echo; printf '\\n__BACKUP_BEGIN__\\n'; "
           b"dd if=/dev/mtdblock5 bs=65536 2>/dev/null | gzip -c | base64; "
           b"printf '\\n__BACKUP_END__\\n'; stty echo\n")
try:
    os.write(fd, b'\n')
    buf = b''
    state = 'login'
    deadline = time.monotonic() + 240
    payload = None
    while time.monotonic() < deadline and payload is None:
        if not select.select([fd], [], [], 1)[0]:
            continue
        try:
            chunk = os.read(fd, 8192)
        except BlockingIOError:
            continue
        if not chunk:
            continue
        buf = (buf + chunk)[-1500000:]
        if state == 'login':
            if b'login:' in buf[-200:]:
                os.write(fd, b'root\n'); buf = b''; state = 'password'
            elif re.search(rb'root@[^\r\n]*[#$] ?$', buf[-200:]):
                state = 'send'
        elif state == 'password' and b'Password:' in buf:
            os.write(fd, password + b'\n'); buf = b''; state = 'login'
        if state == 'send':
            for index in range(0, len(command), 48):
                os.write(fd, command[index:index + 48]); time.sleep(.02)
            state = 'data'; buf = b''
        elif state == 'data':
            begin = re.search(rb'[\r\n]__BACKUP_BEGIN__[\r\n]', buf)
            if begin:
                end = re.search(rb'[\r\n]__BACKUP_END__[\r\n]', buf[begin.end():])
                if end:
                    payload = buf[begin.end():begin.end() + end.start()]
    if payload is None:
        sys.exit('backup markers not found before the deadline')
    text = re.sub(rb'[^A-Za-z0-9+/=]', b'', payload)
    data = gzip.decompress(base64.b64decode(text))
    with open(os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'wb') as handle:
        handle.write(data)
    print(out, len(data), hashlib.sha256(data).hexdigest())
finally:
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    os.close(fd)
