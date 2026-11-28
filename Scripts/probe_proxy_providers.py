#!/usr/bin/env python3
"""Loopback subscription, SOCKS upstream and echo fixtures for the provider integration test."""
import http.server
import json
import pathlib
import select
import socket
import socketserver
import struct
import sys
import threading


def read(sock, size):
    data = b""
    while len(data) < size:
        packet = sock.recv(size - len(data))
        if not packet:
            raise EOFError()
        data += packet
    return data


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(4096):
            self.request.sendall(data)


class Socks(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        try:
            version, size = read(client, 2)
            assert version == 5 and b"\0" in read(client, size)
            client.sendall(b"\x05\x00")
            assert read(client, 4) == b"\x05\x01\x00\x01"
            host = socket.inet_ntoa(read(client, 4))
            assert host == "127.0.0.1"
            port, = struct.unpack("!H", read(client, 2))
            if port == gate.server_port:
                port = http.server_port
            with socket.create_connection((host, port), timeout=2) as upstream:
                client.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                while True:
                    readable, _, _ = select.select([client, upstream], [], [], 15)
                    if not readable:
                        return
                    for item in readable:
                        data = item.recv(4096)
                        if not data:
                            return
                        (client if item is upstream else upstream).sendall(data)
        except (OSError, EOFError, AssertionError):
            pass


requests_lock = threading.Lock()
requests = {}


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.partition("?")[0][1:]
        if name not in {"first", "second", "replacement", "invalid", "fails-on-apply"}:
            self.send_error(404)
            return
        with requests_lock:
            requests[name] = requests.get(name, 0) + 1
            attempt = requests[name]
        if name == "invalid" or name == "fails-on-apply" and attempt > 1:
            content = "proxies: []\n"
        else:
            content = (f"proxies: [{{name: {name}, type: socks5, server: 127.0.0.1, "
                       f"port: {socks.server_address[1]}}}]\n")
        data = content.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class DirectFailure(HTTP):
    def do_GET(self):
        self.send_error(503)


def start(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


socks = start(socketserver.ThreadingTCPServer(("127.0.0.1", 0), Socks))
first = start(socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo))
second = start(socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo))
http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), HTTP)
gate = start(type(http)(("127.0.0.1", 0), DirectFailure))
ready = pathlib.Path(sys.argv[1])
tmp = ready.with_suffix(".tmp")
tmp.write_text(json.dumps({"http": http.server_port, "gate": gate.server_port, "socks": socks.server_address[1],
                           "first": first.server_address[1], "second": second.server_address[1]}))
tmp.replace(ready)
http.serve_forever()
