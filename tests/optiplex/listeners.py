#!/usr/bin/env python3
"""Test-only listeners for the firewall matrix of the hermetic test.

usage: listeners.py tcp:80 udp:3478 ...

Binds every port on :: (dual stack, so v4 and v6) and answers: TCP accepts and closes, UDP
echoes the datagram. A port that something else already listens on (sshd on 25560) is skipped:
the real service is then the thing under test.
"""
import selectors
import socket
import sys

sel = selectors.DefaultSelector()
for spec in sys.argv[1:]:
    proto, port = spec.split(":")
    kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
    s = socket.socket(socket.AF_INET6, kind)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
    try:
        s.bind(("::", int(port)))
    except OSError as e:
        print(f"skip {spec}: {e}", flush=True)
        s.close()
        continue
    if proto == "tcp":
        s.listen(16)
    s.setblocking(False)
    sel.register(s, selectors.EVENT_READ, proto)
    print(f"listening {spec}", flush=True)
print("ready", flush=True)

while True:
    for key, _ in sel.select():
        s = key.fileobj
        if key.data == "tcp":
            c, _ = s.accept()
            c.close()
        else:
            data, addr = s.recvfrom(1024)
            s.sendto(data, addr)
