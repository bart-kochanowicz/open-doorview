import base64
import hashlib
import os
from pathlib import Path
import re
import select
import sys
import termios
import time
import tty

archive = Path(sys.argv[1]).read_bytes()
password = Path(sys.argv[2]).read_bytes().strip()
digest = hashlib.sha256(archive).hexdigest()
port = os.environ.get('DOORVIEW_UART') or sys.exit('Set DOORVIEW_UART to the serial device (for example /dev/ttyUSB0 or /dev/cu.usbserial-XXXX)')
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
tty.setraw(fd)
raw = termios.tcgetattr(fd)
raw[4] = raw[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, raw)

def send(data):
    while data:
        if not select.select([], [fd], [], 4)[1]:
            raise RuntimeError('UART write deadline exceeded')
        data = data[os.write(fd, data):]

def wait(pattern, seconds):
    end = time.monotonic() + seconds
    buffer = b''
    while time.monotonic() < end and select.select([fd], [], [], max(0, end - time.monotonic()))[0]:
        buffer = (buffer + os.read(fd, 4096))[-16000:]
        if re.search(pattern, buffer):
            return buffer
    raise RuntimeError('UART transfer state timed out')

try:
    prompt = rb'root@[^\r\n]*#'
    send(b'\n')
    if b'login:' in wait(rb'login:|' + prompt, 8):
        send(b'root\n')
        wait(rb'Password:', 5)
        send(password + b'\n')
        wait(prompt, 8)
    command = ("umask 077; mkdir -p /tmp/doorview-upload && cd /tmp/doorview-upload && "
               "old_tty=$(stty -g) && stty -echo && printf '\\nLCD_UPLOAD_READY\\n' && "
               "timeout 90 base64 -d > live-upload.tgz; upload=$?; stty \"$old_tty\"; "
               f"test \"$upload\" = 0 && echo '{digest}  live-upload.tgz' | sha256sum -c - && "
               "gzip -dc live-upload.tgz | tar -xof -; "
               "if test \"$?\" = 0; then rm -f live-upload.tgz; printf '\\nLCD_UPLOAD_DONE\\n'; fi\n")
    for index in range(0, len(command), 48):
        send(command[index:index + 48].encode())
        time.sleep(.02)
    wait(rb'[\r\n]LCD_UPLOAD_READY[\r\n]', 8)
    print(f'Sending {len(archive)} bytes of compressed test files over UART', flush=True)
    data = base64.encodebytes(archive)
    for index in range(0, len(data), 1024):
        send(data[index:index + 1024])
        time.sleep(.145)
    send(b'\x04')
    result = wait(rb'[\r\n]LCD_UPLOAD_DONE[\r\n]|' + prompt, 15)
    if not re.search(rb'[\r\n]LCD_UPLOAD_DONE[\r\n]', result):
        sys.exit(result.replace(password, b'[redacted]').decode(errors='replace').strip())
    print('Camera RAM archive SHA-256 verified and unpacked', flush=True)
finally:
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    os.close(fd)
