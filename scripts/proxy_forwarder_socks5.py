#!/usr/bin/env python3
"""
proxy_forwarder_socks5.py — HTTP/CONNECT proxy that forwards through
an upstream SOCKS5 proxy (e.g. coldproxy residential).

Runs on the Mac. Each vphone VM connects to this on a unique port via
regular HTTP/HTTPS system proxy. The forwarder connects outbound via
SOCKS5 to the upstream proxy.

Usage:
    python3 proxy_forwarder_socks5.py --port 12322 \
        --socks5 gw-98959.coldproxy.com:32466 \
        --socks5-auth 'username:password'

Port convention: 12320 + VM number (vm2 = 12322, vm9 = 12329)
"""

import argparse
import base64
import struct
import socket
import threading
import sys
import signal


SOCKS5_NO_AUTH = 0x00
SOCKS5_USER_PASS = 0x02
SOCKS5_NO_ACCEPTABLE = 0xFF


def socks5_connect(upstream_host, upstream_port, username, password, target_host, target_port):
    """Connect to target via upstream SOCKS5 proxy with username/password auth."""
    import sys
    sock = socket.create_connection((upstream_host, upstream_port), timeout=30)

    try:
        # Greeting — offer no-auth and user/pass
        has_auth = bool(username or password)
        methods = [SOCKS5_NO_AUTH]
        if has_auth:
            methods.append(SOCKS5_USER_PASS)
        sock.sendall(b"\x05" + bytes([len(methods)]) + bytes(methods))

        resp = sock.recv(2)
        if len(resp) < 2 or resp[0] != 0x05:
            print(f"[socks5] Bad greeting response: {resp.hex()}", file=sys.stderr)
            sock.close()
            return None

        chosen_method = resp[1]
        print(f"[socks5] Auth method chosen: {chosen_method} (0=none, 2=userpass)", file=sys.stderr)

        if chosen_method == SOCKS5_USER_PASS:
            if not has_auth:
                sock.close()
                return None
            # RFC 1929 auth
            uenc = (username or "").encode()
            penc = (password or "").encode()
            auth_msg = bytes([0x01, len(uenc)]) + uenc + bytes([len(penc)]) + penc
            sock.sendall(auth_msg)
            auth_resp = sock.recv(2)
            if len(auth_resp) < 2 or auth_resp[1] != 0x00:
                print(f"[socks5] Auth FAILED for user: {username[:40]}...", file=sys.stderr)
                sock.close()
                return None
            print(f"[socks5] Auth OK for user: {username[:60]}...", file=sys.stderr)
        elif chosen_method == SOCKS5_NO_AUTH:
            print(f"[socks5] WARNING: upstream chose no-auth — session stickiness unlikely", file=sys.stderr)
            pass
        elif chosen_method == SOCKS5_NO_ACCEPTABLE:
            sock.close()
            return None

        # CONNECT request — domain name type (0x03)
        target_enc = target_host.encode()
        req = (
            b"\x05\x01\x00\x03"
            + bytes([len(target_enc)]) + target_enc
            + struct.pack("!H", target_port)
        )
        sock.sendall(req)

        # Response: VER REP RSV ATYP + bind addr/port
        resp = sock.recv(4)
        if len(resp) < 4 or resp[0] != 0x05 or resp[1] != 0x00:
            rep_code = resp[1] if len(resp) > 1 else -1
            print(f"[socks5] CONNECT to {target_host}:{target_port} FAILED (rep={rep_code})", file=sys.stderr)
            sock.close()
            return None
        print(f"[socks5] CONNECT to {target_host}:{target_port} OK", file=sys.stderr)

        atyp = resp[3]
        if atyp == 0x01:  # IPv4
            sock.recv(4 + 2)
        elif atyp == 0x03:  # Domain
            dlen = sock.recv(1)[0]
            sock.recv(dlen + 2)
        elif atyp == 0x04:  # IPv6
            sock.recv(16 + 2)

        return sock
    except Exception:
        sock.close()
        return None


def forward_data(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except (OSError, BrokenPipeError):
        pass
    finally:
        try:
            src.close()
        except OSError:
            pass
        try:
            dst.close()
        except OSError:
            pass


def handle_connect(client_sock, socks5_host, socks5_port, socks5_user, socks5_pass, target_host, target_port):
    result = socks5_connect(socks5_host, socks5_port, socks5_user, socks5_pass, target_host, target_port)
    if result is None:
        client_sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        client_sock.close()
        return

    client_sock.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

    t1 = threading.Thread(target=forward_data, args=(client_sock, result), daemon=True)
    t2 = threading.Thread(target=forward_data, args=(result, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


def handle_http(client_sock, raw_request, socks5_host, socks5_port, socks5_user, socks5_pass):
    first_line = raw_request.split(b"\r\n")[0].decode()
    parts = first_line.split(" ")
    url = parts[1] if len(parts) > 1 else ""

    if url.startswith("http://"):
        from urllib.parse import urlparse
        parsed = urlparse(url)
        target_host = parsed.hostname
        target_port = parsed.port or 80
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
    else:
        client_sock.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
        client_sock.close()
        return

    upstream = socks5_connect(socks5_host, socks5_port, socks5_user, socks5_pass, target_host, target_port)
    if upstream is None:
        client_sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        client_sock.close()
        return

    new_request = f"{parts[0]} {path} {parts[2]}\r\n".encode()
    rest = raw_request.split(b"\r\n", 1)[1] if b"\r\n" in raw_request else b""
    upstream.sendall(new_request + rest)

    t1 = threading.Thread(target=forward_data, args=(upstream, client_sock), daemon=True)
    t2 = threading.Thread(target=forward_data, args=(client_sock, upstream), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


def handle_client(client_sock, socks5_host, socks5_port, socks5_user, socks5_pass):
    try:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = client_sock.recv(65536)
            if not chunk:
                client_sock.close()
                return
            request += chunk

        first_line = request.split(b"\r\n")[0].decode()
        method = first_line.split(" ")[0]

        if method == "CONNECT":
            target = first_line.split(" ")[1]
            if ":" in target:
                host, port = target.rsplit(":", 1)
                port = int(port)
            else:
                host = target
                port = 443
            handle_connect(client_sock, socks5_host, socks5_port, socks5_user, socks5_pass, host, port)
        else:
            handle_http(client_sock, request, socks5_host, socks5_port, socks5_user, socks5_pass)
    except Exception:
        try:
            client_sock.sendall(b"HTTP/1.1 500 Internal Server Error\r\n\r\n")
        except OSError:
            pass
        client_sock.close()


def main():
    parser = argparse.ArgumentParser(description="HTTP/CONNECT → SOCKS5 proxy forwarder for vphone VMs")
    parser.add_argument("--port", type=int, required=True, help="Local port to listen on (12320 + VM number)")
    parser.add_argument("--socks5", required=True, help="Upstream SOCKS5 proxy host:port")
    parser.add_argument("--socks5-auth", default="", help="Upstream SOCKS5 username:password")
    parser.add_argument("--bind", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    args = parser.parse_args()

    socks5_host, socks5_port = args.socks5.rsplit(":", 1)
    socks5_port = int(socks5_port)
    socks5_user = ""
    socks5_pass = ""
    if args.socks5_auth:
        if ":" in args.socks5_auth:
            socks5_user, socks5_pass = args.socks5_auth.split(":", 1)
        else:
            socks5_user = args.socks5_auth

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(128)

    print(f"[socks5-proxy] Listening on {args.bind}:{args.port}")
    print(f"[socks5-proxy] Upstream SOCKS5: {socks5_host}:{socks5_port}")
    print(f"[socks5-proxy] User: {socks5_user[:30]}...")

    def shutdown(sig, frame):
        print("\n[socks5-proxy] Shutting down")
        server.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    while True:
        try:
            client_sock, addr = server.accept()
            t = threading.Thread(
                target=handle_client,
                args=(client_sock, socks5_host, socks5_port, socks5_user, socks5_pass),
                daemon=True,
            )
            t.start()
        except OSError:
            break


if __name__ == "__main__":
    main()
