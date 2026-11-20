#!/usr/bin/env python3
import os, re, select, sys, termios, time, tty
port=os.environ.get('DOORVIEW_UART') or sys.exit('Set DOORVIEW_UART to the serial device (for example /dev/ttyUSB0 or /dev/cu.usbserial-XXXX)')
out=sys.argv[1]
pwd=sys.stdin.buffer.readline().rstrip(b'\r\n')
fd=os.open(port, os.O_RDWR|os.O_NOCTTY|os.O_NONBLOCK)
tty.setraw(fd)
a=termios.tcgetattr(fd); a[4]=a[5]=termios.B115200; termios.tcsetattr(fd,termios.TCSANOW,a)
log=open(out,'wb')
def emit(data):
    if pwd: data=data.replace(pwd,b'[redacted]')
    log.write(data); log.flush()
os.write(fd,b'\n')
buf=b''; sent=False; end=time.monotonic()+120
while time.monotonic()<end:
    if not select.select([fd],[],[],1)[0]: continue
    try: chunk=os.read(fd,4096)
    except BlockingIOError: continue
    if not chunk: continue
    emit(chunk); buf=(buf+chunk)[-16000:]
    if not sent and b'login:' in buf:
        os.write(fd,b'root\n'); buf=b''
    elif not sent and b'Password:' in buf:
        os.write(fd,pwd+b'\n'); buf=b''
    elif not sent and re.search(rb'root@[^\r\n]*[#$] ?',buf):
        cmd=b'stty -echo; echo __PRE_REBOOT__; cat /proc/uptime; dmesg | grep "FIFO empty" | tail -1; echo __REBOOTING__; reboot\n'
        for i in range(0,len(cmd),48): os.write(fd,cmd[i:i+48]); time.sleep(.02)
        sent=True; buf=b''
log.close()
