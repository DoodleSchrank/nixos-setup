#!/usr/bin/env python3
"""probe.py tcp|udp HOST PORT: exit 0 if the port answers within 2 seconds, 1 otherwise.

TCP: the connection is accepted. UDP: the echo of listeners.py comes back.
A dropping firewall ends in the timeout, so "closed" costs 2 seconds.
"""
import socket
import sys

proto, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
family = socket.AF_INET6 if ":" in host else socket.AF_INET
kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
s = socket.socket(family, kind)
s.settimeout(2)
try:
    if proto == "tcp":
        s.connect((host, port))
    else:
        s.sendto(b"ping", (host, port))
        s.recvfrom(1024)
except OSError:
    sys.exit(1)
sys.exit(0)
