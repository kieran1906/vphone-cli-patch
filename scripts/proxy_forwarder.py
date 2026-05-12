#!/usr/bin/env python3
"""
proxy_forwarder.py — Lightweight HTTP/CONNECT proxy that forwards through
an upstream authenticated proxy (e.g. iproyal residential).

Runs on the Mac. Each vphone VM connects to this on a unique port.
The VM's iOS system proxy points to the Mac gateway (192.168.64.1:PORT).

Usage:
    python3 proxy_forwarder.py --port 12322 \
        --upstream geo.iproyal.com:12321 \
        --upstream-auth 'user:pass_country-us_session-XXXX_lifetime-10m'

Port convention: 12320 + VM number (vm2 = 12322, vm9 = 12329)
"""

import argparse
import base64
import select
import socket
import threading
import sys
import signal
import time


def forward_data(src, dst, label=""):
    """Forward data between two sockets until one closes."""
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


def connect_upstream(upstream_host, upstream_port, upstream_auth, target_host, target_port):
    """Connect to target via upstream CONNECT proxy with auth."""
    sock = socket.create_connection((upstream_host, upstream_port), timeout=30)
    auth_b64 = base64.b64encode(upstream_auth.encode()).decode()
    connect_req = (
        f"CONNECT {target_host}:{target_port} HTTP/1.1\r\n"
        f"Host: {target_host}:{target_port}\r\n"
        f"Proxy-Authorization: Basic {auth_b64}\r\n"
        f"\r\n"
    )
    sock.sendall(connect_req.encode())

    response = b""
    while b"\r\n\r\n" not in response:
        chunk = sock.recv(4096)
        if not chunk:
            sock.close()
            return None
        response += chunk

    status_line = response.split(b"\r\n")[0].decode()
    if "200" in status_line:
        # Send any remaining data after headers
        remaining = response.split(b"\r\n\r\n", 1)[1]
        return sock, remaining
    else:
        sock.close()
        return None


def handle_connect(client_sock, upstream_host, upstream_port, upstream_auth, target_host, target_port):
    """Handle HTTPS CONNECT tunnel."""
    result = connect_upstream(upstream_host, upstream_port, upstream_auth, target_host, target_port)
    if result is None:
        client_sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        client_sock.close()
        return

    upstream_sock, remaining = result
    client_sock.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")

    if remaining:
        upstream_sock.sendall(remaining)

    t1 = threading.Thread(target=forward_data, args=(client_sock, upstream_sock, "c->u"), daemon=True)
    t2 = threading.Thread(target=forward_data, args=(upstream_sock, client_sock, "u->c"), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()


def handle_http(client_sock, raw_request, upstream_host, upstream_port, upstream_auth):
    """Handle plain HTTP request via upstream proxy."""
    auth_b64 = base64.b64encode(upstream_auth.encode()).decode()

    # Insert Proxy-Authorization header
    lines = raw_request.split(b"\r\n")
    new_lines = [lines[0]]
    new_lines.append(f"Proxy-Authorization: Basic {auth_b64}".encode())
    new_lines.extend(lines[1:])
    modified_request = b"\r\n".join(new_lines)

    try:
        upstream_sock = socket.create_connection((upstream_host, upstream_port), timeout=30)
        upstream_sock.sendall(modified_request)
        forward_data(upstream_sock, client_sock, "proxy-http")
    except (OSError, BrokenPipeError):
        try:
            client_sock.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except OSError:
            pass
    finally:
        client_sock.close()


def handle_client(client_sock, upstream_host, upstream_port, upstream_auth):
    """Handle incoming client connection."""
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
            # CONNECT host:port HTTP/1.1
            target = first_line.split(" ")[1]
            if ":" in target:
                host, port = target.rsplit(":", 1)
                port = int(port)
            else:
                host = target
                port = 443
            handle_connect(client_sock, upstream_host, upstream_port, upstream_auth, host, port)
        else:
            # Regular HTTP — forward via upstream proxy
            handle_http(client_sock, request, upstream_host, upstream_port, upstream_auth)
    except Exception as e:
        try:
            client_sock.sendall(b"HTTP/1.1 500 Internal Server Error\r\n\r\n")
        except OSError:
            pass
        client_sock.close()


def main():
    parser = argparse.ArgumentParser(description="HTTP/CONNECT proxy forwarder for vphone VMs")
    parser.add_argument("--port", type=int, required=True, help="Local port to listen on (12320 + VM number)")
    parser.add_argument("--upstream", required=True, help="Upstream proxy host:port (e.g. geo.iproyal.com:12321)")
    parser.add_argument("--upstream-auth", required=True, help="Upstream proxy user:pass")
    parser.add_argument("--bind", default="0.0.0.0", help="Bind address (default: 0.0.0.0)")
    args = parser.parse_args()

    upstream_host, upstream_port = args.upstream.rsplit(":", 1)
    upstream_port = int(upstream_port)

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(128)

    print(f"[proxy] Listening on {args.bind}:{args.port}")
    print(f"[proxy] Upstream: {upstream_host}:{upstream_port}")
    print(f"[proxy] Auth: {args.upstream_auth[:20]}...")

    def shutdown(sig, frame):
        print("\n[proxy] Shutting down")
        server.close()
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    while True:
        try:
            client_sock, addr = server.accept()
            t = threading.Thread(
                target=handle_client,
                args=(client_sock, upstream_host, upstream_port, args.upstream_auth),
                daemon=True,
            )
            t.start()
        except OSError:
            break


if __name__ == "__main__":
    main()
