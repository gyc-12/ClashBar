#!/usr/bin/env python3
"""TCP process-rule probe for a supplied independent loopback core; no core discovery."""
import ctypes
import json
import os
import pathlib
import socket
import struct
import sys
import threading
import time
import urllib.request

proxy_port = int(sys.argv[1])
ready, done = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
stop = threading.Event()
results = {"tcp_echoes": 0, "tcp_errors": []}


def exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise RuntimeError("TCP connection closed")
        data += chunk
    return data


server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen()
server.settimeout(0.1)
target_port = server.getsockname()[1]


def serve():
    while not stop.is_set():
        try:
            connection, _ = server.accept()
        except socket.timeout:
            continue
        threading.Thread(target=serve_connection, args=(connection,), daemon=True).start()


def serve_connection(connection):
    with connection:
        connection.settimeout(0.1)
        while not stop.is_set():
            try:
                data = connection.recv(1024)
                if not data:
                    break
                connection.sendall(data)
            except socket.timeout:
                continue
            except OSError:
                break


def connect():
    sock = socket.create_connection(("127.0.0.1", proxy_port), timeout=2)
    sock.settimeout(2)
    sock.sendall(b"\x05\x01\x00")
    if exact(sock, 2) != b"\x05\x00":
        raise RuntimeError("SOCKS authentication failed")
    sock.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", target_port))
    response = exact(sock, 4)
    length = 4 if response[3] == 1 else 16 if response[3] == 4 else exact(sock, 1)[0]
    exact(sock, length + 2)
    return sock, response[1]


threading.Thread(target=serve, daemon=True).start()
tcp, status = connect()
if status:
    raise RuntimeError("Initial DIRECT connection rejected")


def traffic():
    while not stop.is_set():
        try:
            message = struct.pack("!I", results["tcp_echoes"])
            tcp.sendall(message)
            if exact(tcp, 4) != message:
                raise RuntimeError("Echo differs")
            results["tcp_echoes"] += 1
            time.sleep(0.005)
        except Exception as error:
            results["tcp_errors"].append(str(error))
            break


worker = threading.Thread(target=traffic, daemon=True)
worker.start()
buffer = ctypes.create_string_buffer(4096)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
if libproc.proc_pidpath(os.getpid(), buffer, len(buffer)) <= 0:
    raise RuntimeError("Cannot read this probe's executable path")
process_path = os.fsdecode(buffer.value)
temporary = ready.with_suffix(".tmp")
temporary.write_text(json.dumps({"process_path": process_path, "process_name": pathlib.Path(process_path).name}))
temporary.replace(ready)
deadline = time.monotonic() + 15
try:
    while not done.exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Independent test reload did not finish")
        time.sleep(0.005)
    before = results["tcp_echoes"]
    time.sleep(0.2)
    results["echoes_after_reload"] = results["tcp_echoes"] - before
    fresh, status = connect()
    rejected = status != 0
    if not rejected:
        try:
            fresh.sendall(b"test")
            rejected = fresh.recv(4) == b""
        except ConnectionResetError:
            rejected = True
    if not rejected and len(sys.argv) > 4:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f"http://127.0.0.1:{int(sys.argv[4])}/connections", timeout=2) as response:
            snapshot = json.load(response)
        results["observed_metadata"] = [c.get("metadata") for c in snapshot.get("connections", [])
                                        if str(c.get("metadata", {}).get("destinationPort")) == str(target_port)]
    fresh.close()
    results["new_process_connection_rejected"] = rejected
finally:
    stop.set()
    worker.join(timeout=2)
    tcp.close()
    server.close()
print(json.dumps(results))
if results["tcp_errors"] or results["echoes_after_reload"] < 5 or not results["new_process_connection_rejected"]:
    sys.exit(1)
