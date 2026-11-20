#!/usr/bin/env python3
"""Run one shell command over the RH-PD10 UART console and print its output.

Usage: printf '<root-password>\\n' | dv-uart-cmd.py '<command>'

The password is only used when the console presents a login prompt. When a root
shell is already open, the line is consumed locally and never sent to the device.
Keep exactly one reader on the serial port at a time.
"""
import os
import re
import select
import sys
import termios
import time
import tty

PORT = os.environ.get('DOORVIEW_UART') or sys.exit('Set DOORVIEW_UART to the serial device (for example /dev/ttyUSB0 or /dev/cu.usbserial-XXXX)')
BAUD = termios.B115200
TIMEOUT = 40

if len(sys.argv) < 2:
    raise SystemExit(__doc__)
command = sys.argv[1].encode()

if sys.stdin.isatty():
    attrs = termios.tcgetattr(sys.stdin.fileno())
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, attrs)
pwd = sys.stdin.buffer.readline().rstrip(b'\r\n')

fd = os.open(PORT, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
tty.setraw(fd)
attrs = termios.tcgetattr(fd)
attrs[4] = attrs[5] = BAUD
termios.tcsetattr(fd, termios.TCSANOW, attrs)

os.write(fd, b'\n')
buf = b''
state = 'login'
end = time.monotonic() + TIMEOUT

while time.monotonic() < end:
    if not select.select([fd], [], [], 1)[0]:
        continue
    chunk = os.read(fd, 4096)
    buf = (buf + chunk)[-32000:]
    if state == 'login' and b'login:' in buf:
        os.write(fd, b'root\n')
        buf = b''
        state = 'password'
    elif state == 'password' and b'Password:' in buf:
        os.write(fd, pwd + b'\n')
        buf = b''
        state = 'shell'
    elif state in ('login', 'shell') and re.search(rb'root@[^\r\n]*[#$] ?', buf):
        payload = command + b'; echo __CMD_DONE__\n'
        for i in range(0, len(payload), 48):
            os.write(fd, payload[i:i + 48])
            time.sleep(0.02)
        buf = b''
        state = 'output'
    elif state == 'output':
        sys.stdout.buffer.write(chunk.replace(pwd, b'[redacted]') if pwd else chunk)
        sys.stdout.buffer.flush()
        if re.search(rb'[\r\n]__CMD_DONE__[\r\n]', buf):
            break
else:
    raise SystemExit('UART command timed out (state=%s)' % state)
