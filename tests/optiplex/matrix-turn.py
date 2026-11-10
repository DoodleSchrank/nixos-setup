"""STUN/TURN checks against the Optiplex coturn (VM test of ticket 31, runs on the `outside` client).

usage: matrix-turn.py <server> <shared-secret> <expected-relay-ip> <relay-min> <relay-max> <host-lan-ip> <sink-port>

Speaks raw TURN over UDP (RFC 5766 long-term credentials, coturn REST secret):
  1. Allocate without credentials            -> 401 (refused)
  2. Allocate with a wrong password          -> 401 (refused)
  3. Allocate with HMAC credentials          -> success, relayed address = expected IP, port in the range
  4. CreatePermission for a public peer      -> success
  5. CreatePermission for private peers      -> 403 (denied-peer-ip): LAN v4, ULA, loopback, link-local
  6. Allocate asking for an IPv6 relay       -> 440 (relays are IPv4 only)
  7. Data to the host's own address          -> coturn exempts its own addresses from denied-peer-ip, so the
     CreatePermission works; the nftables egress filter must drop the data (the caller checks the sink)
Exits non-zero with a message on the first failed expectation.
"""
import base64, hashlib, hmac, os, socket, struct, sys, time

COOKIE = 0x2112A442
A_USERNAME, A_MI, A_ERROR, A_REALM, A_NONCE = 0x0006, 0x0008, 0x0009, 0x0014, 0x0015
A_REQ_TRANSPORT, A_XOR_PEER, A_XOR_RELAYED, A_REQ_FAMILY = 0x0019, 0x0012, 0x0016, 0x0017
ALLOCATE, ALLOCATE_OK, ALLOCATE_ERR = 0x0003, 0x0103, 0x0113
PERM, PERM_OK, PERM_ERR = 0x0008, 0x0108, 0x0118


def attr(t, v):
    return struct.pack("!HH", t, len(v)) + v + b"\0" * (-len(v) % 4)


def msg(mtype, attrs, key=None):
    txid = os.urandom(12)
    # an attribute is bytes, or a function of the transaction id (IPv6 XOR addresses need it)
    body = b"".join(a(txid) if callable(a) else a for a in attrs)
    if key is not None:
        # MESSAGE-INTEGRITY covers the header with the length including the MI attribute itself
        hdr = struct.pack("!HHI", mtype, len(body) + 24, COOKIE) + txid
        body += attr(A_MI, hmac.new(key, hdr + body, hashlib.sha1).digest())
    return struct.pack("!HHI", mtype, len(body), COOKIE) + txid + body


def parse(data):
    mtype, length, cookie = struct.unpack("!HHI", data[:8])
    assert cookie == COOKIE, "not a STUN message"
    attrs, i = {}, 20
    while i < 20 + length:
        t, l = struct.unpack("!HH", data[i : i + 4])
        attrs[t] = data[i + 4 : i + 4 + l]
        i += 4 + l + (-l % 4)
    return mtype, attrs


def error_code(attrs):
    v = attrs.get(A_ERROR, b"\0\0\0\0")
    return v[2] * 100 + v[3]


def xor_peer(ip):
    def build(txid):
        if ":" in ip:
            raw = socket.inet_pton(socket.AF_INET6, ip)
            mask = struct.pack("!I", COOKIE) + txid
            return attr(A_XOR_PEER, struct.pack("!BBH", 0, 2, 0x2112) + bytes(a ^ b for a, b in zip(raw, mask)))
        raw = socket.inet_aton(ip)
        return attr(A_XOR_PEER, struct.pack("!BBH", 0, 1, 0x2112) + bytes(a ^ b for a, b in zip(raw, struct.pack("!I", COOKIE))))
    return build


def decode_xor_addr(v):
    port = struct.unpack("!H", v[2:4])[0] ^ 0x2112
    ip = socket.inet_ntoa(bytes(a ^ b for a, b in zip(v[4:8], struct.pack("!I", COOKIE))))
    return ip, port


class Turn:
    def __init__(self, server):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.settimeout(5)
        self.addr = (server, 3478)

    def rpc(self, mtype, attrs, key=None):
        self.s.sendto(msg(mtype, attrs, key), self.addr)
        try:
            return parse(self.s.recv(4096))
        except socket.timeout:
            fail("no answer from the TURN server (5 s)")


def fail(text):
    print("FAIL:", text)
    sys.exit(1)


def main():
    server, secret, want_ip, rmin, rmax = sys.argv[1], sys.argv[2].encode(), sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    host_lan, sink = sys.argv[6], int(sys.argv[7])
    udp = attr(A_REQ_TRANSPORT, b"\x11\0\0\0")
    user = f"{int(time.time()) + 3600}:test".encode()

    def challenge():
        # coturn's nonces are bound to the client's address and port: every socket asks for its own
        t = Turn(server)
        mtype, a = t.rpc(ALLOCATE, [udp])
        if mtype != ALLOCATE_ERR or error_code(a) != 401:
            fail(f"allocate without credentials: type {mtype:#x} code {error_code(a)}, expected 401")
        return t, a[A_REALM], a[A_NONCE]

    def creds(realm, nonce, password, extra=()):
        key = hashlib.md5(user + b":" + realm + b":" + password).digest()
        return key, [udp, *extra, attr(A_USERNAME, user), attr(A_REALM, realm), attr(A_NONCE, nonce)]

    # 1. no credentials: coturn answers 401 with its realm and a nonce
    t, realm, nonce = challenge()
    print("1 ok: allocate without credentials -> 401, realm", realm.decode())

    # 2. wrong password
    t2, realm2, nonce2 = challenge()
    key, attrs = creds(realm2, nonce2, base64.b64encode(hmac.new(b"not-the-secret", user, hashlib.sha1).digest()))
    mtype, a = t2.rpc(ALLOCATE, attrs, key)
    if mtype != ALLOCATE_ERR or error_code(a) not in (401, 438):
        fail(f"allocate with a wrong password: type {mtype:#x} code {error_code(a)}, expected 401")
    print("2 ok: allocate with a wrong password ->", error_code(a))

    # 3. right credentials
    pw = base64.b64encode(hmac.new(secret, user, hashlib.sha1).digest())
    t3, realm3, nonce3 = challenge()
    key, attrs = creds(realm3, nonce3, pw)
    mtype, a = t3.rpc(ALLOCATE, attrs, key)
    if mtype != ALLOCATE_OK:
        fail(f"allocate with HMAC credentials: type {mtype:#x} code {error_code(a)}, expected success")
    ip, port = decode_xor_addr(a[A_XOR_RELAYED])
    if ip != want_ip or not rmin <= port <= rmax:
        fail(f"relayed address {ip}:{port}, expected {want_ip}:{rmin}-{rmax}")
    print(f"3 ok: allocation with HMAC credentials -> relay {ip}:{port}")

    # 4. a public peer may be permitted; 5. private peers may not
    def perm(peer):
        return t3.rpc(PERM, [xor_peer(peer), attr(A_USERNAME, user), attr(A_REALM, realm3), attr(A_NONCE, nonce3)], key)

    mtype, a = perm("8.8.8.8")
    if mtype != PERM_OK:
        fail(f"permission for 8.8.8.8: type {mtype:#x} code {error_code(a)}, expected success")
    print("4 ok: CreatePermission 8.8.8.8 -> success")
    for peer in ("192.168.178.50", "10.0.0.1", "169.254.1.1", "172.16.0.1", "203.0.113.10"):
        mtype, a = perm(peer)
        if mtype != PERM_ERR or error_code(a) != 403:
            fail(f"permission for {peer}: type {mtype:#x} code {error_code(a)}, expected 403")
        print(f"5 ok: CreatePermission {peer} -> 403")
    # IPv6 and IPv4-mapped peers (the LAN's ULA and global addresses, loopback, ...): never permitted
    for peer in ("fd65:c1a5:7d2b::50", "2001:db8:2::10", "::1", "fe80::1", "::ffff:192.168.178.50", "::ffff:127.0.0.1"):
        mtype, a = perm(peer)
        if mtype == PERM_OK:
            fail(f"permission for IPv6 peer {peer} was granted")
        print(f"5 ok: CreatePermission {peer} -> {error_code(a)}")

    # 7. the host's own addresses are not denied by coturn (it exempts them): permission works, data must not arrive
    def xor_port_peer(ip, port):
        raw = socket.inet_aton(ip)
        return attr(A_XOR_PEER, struct.pack("!BBH", 0, 1, port ^ 0x2112) + bytes(a ^ b for a, b in zip(raw, struct.pack("!I", COOKIE))))
    for peer in (host_lan, "127.0.0.1"):
        t3.rpc(PERM, [xor_peer(peer), attr(A_USERNAME, user), attr(A_REALM, realm3), attr(A_NONCE, nonce3)], key)
        t3.s.sendto(msg(0x0016, [xor_port_peer(peer, sink), attr(0x0013, b"must-not-arrive")]), t3.addr)
    print("7 done: data sent to the host's own addresses, port", sink)

    # 6. another allocation asking for an IPv6 relay
    t4, realm4, nonce4 = challenge()
    key4, attrs4 = creds(realm4, nonce4, pw, extra=[attr(A_REQ_FAMILY, b"\x02\0\0\0")])
    mtype, a = t4.rpc(ALLOCATE, attrs4, key4)
    if mtype == ALLOCATE_OK:
        fail("an IPv6 relay was allocated")
    print("6 ok: IPv6 relay request ->", error_code(a))
    print("turn checks passed")


main()
