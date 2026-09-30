#!/usr/bin/env python3
import argparse
import asyncio
import http.server
import json
import os
import select
import socket
import socketserver
import statistics
import threading
import time
from pathlib import Path

BODY = (b"rootless-stability-" * 256)[:4096]


class SharedState:
    def __init__(self, root: Path, nodes: int):
        self.root = root
        self.nodes = nodes
        self.lock = threading.Lock()
        self.counters = [0 for _ in range(nodes)]
        self.active = 0
        self.peak_active = 0

    def phase(self) -> int:
        try:
            return int((self.root / "phase").read_text().strip())
        except Exception:
            return 0

    def behavior(self, index: int):
        phase = self.phase()
        best = phase % self.nodes
        previous = (best - 1) % self.nodes
        runner_up = (best + 1) % self.nodes
        if index == best:
            return 0.002, 0
        if index == previous:
            return 0.180, 11
        if index == runner_up:
            return 0.015, 0
        delay = 0.035 + 0.008 * ((index + phase) % 4)
        if index == (best + 3) % self.nodes:
            return delay, 37
        return delay, 0

    def begin(self, index: int):
        with self.lock:
            self.counters[index] += 1
            n = self.counters[index]
            self.active += 1
            self.peak_active = max(self.peak_active, self.active)
            return n

    def end(self):
        with self.lock:
            self.active -= 1

    def snapshot(self):
        with self.lock:
            return {
                "phase": self.phase(),
                "counters": list(self.counters),
                "active": self.active,
                "peak_active": self.peak_active,
            }


class TargetHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", str(len(BODY)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *_):
        pass


class TargetServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 4096


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    state = None

    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        payload = json.dumps(self.state.snapshot(), sort_keys=True).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_):
        pass


class ProxyHandler(socketserver.BaseRequestHandler):
    state = None
    index = 0

    def handle(self):
        state = self.state
        n = state.begin(self.index)
        try:
            delay, drop_every = state.behavior(self.index)
            if delay:
                time.sleep(delay)
            if drop_every and n % drop_every == 0:
                return

            client = self.request
            client.settimeout(8)
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 65536:
                chunk = client.recv(4096)
                if not chunk:
                    return
                data += chunk

            first = data.split(b"\r\n", 1)[0].decode("latin1", "replace")
            parts = first.split()
            if len(parts) < 2 or parts[0].upper() != "CONNECT":
                client.sendall(
                    b"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\n\r\n"
                )
                return

            host_port = parts[1]
            host, port_text = host_port.rsplit(":", 1)
            host = host.strip("[]")
            try:
                upstream = socket.create_connection((host, int(port_text)), timeout=5)
            except OSError:
                return

            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            client.setblocking(False)
            upstream.setblocking(False)
            sockets = [client, upstream]
            try:
                while True:
                    readable, _, exceptional = select.select(sockets, [], sockets, 5)
                    if exceptional or not readable:
                        break
                    for src in readable:
                        dst = upstream if src is client else client
                        try:
                            buf = src.recv(65536)
                        except BlockingIOError:
                            continue
                        if not buf:
                            return
                        dst.sendall(buf)
            finally:
                upstream.close()
        finally:
            state.end()


class ThreadedProxyServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 4096


def make_proxy_handler(state: SharedState, index: int):
    return type(
        f"ProxyHandler{index}",
        (ProxyHandler,),
        {"state": state, "index": index},
    )


def run_server(args):
    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    (root / "phase").write_text("0\n")

    state = SharedState(root, args.nodes)
    MetricsHandler.state = state

    target = TargetServer((args.host, args.target_port), TargetHandler)
    metrics = TargetServer((args.host, args.metrics_port), MetricsHandler)
    threading.Thread(target=target.serve_forever, daemon=True).start()
    threading.Thread(target=metrics.serve_forever, daemon=True).start()

    servers = []
    for index in range(args.nodes):
        port = args.proxy_base_port + index
        server = ThreadedProxyServer(
            (args.host, port),
            make_proxy_handler(state, index),
        )
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()

    print(
        json.dumps(
            {
                "event": "ready",
                "target_port": args.target_port,
                "metrics_port": args.metrics_port,
                "proxy_ports": [
                    args.proxy_base_port + i for i in range(args.nodes)
                ],
            }
        ),
        flush=True,
    )
    while True:
        time.sleep(60)


async def read_headers(reader: asyncio.StreamReader, timeout: float) -> bytes:
    return await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout=timeout)


async def one_request(
    proxy_host: str,
    proxy_port: int,
    target_host: str,
    target_port: int,
    timeout: float,
):
    started = time.perf_counter()
    writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(proxy_host, proxy_port),
            timeout=timeout,
        )
        connect = (
            f"CONNECT {target_host}:{target_port} HTTP/1.1\r\n"
            f"Host: {target_host}:{target_port}\r\n"
            "Proxy-Connection: close\r\n\r\n"
        ).encode()
        writer.write(connect)
        await writer.drain()
        headers = await read_headers(reader, timeout)
        if not headers.startswith(b"HTTP/1.1 200"):
            raise RuntimeError("CONNECT failed")

        request = (
            f"GET / HTTP/1.1\r\nHost: {target_host}:{target_port}\r\n"
            "Connection: close\r\n\r\n"
        ).encode()
        writer.write(request)
        await writer.drain()
        response = await asyncio.wait_for(reader.read(), timeout=timeout)
        header_end = response.find(b"\r\n\r\n")
        if header_end < 0 or not response.startswith(b"HTTP/1.1 200"):
            raise RuntimeError("target HTTP failed")
        body = response[header_end + 4 :]
        if len(body) != len(BODY):
            raise RuntimeError(f"short body: {len(body)}")
        return True, (time.perf_counter() - started) * 1000.0, ""
    except Exception as exc:
        return False, (time.perf_counter() - started) * 1000.0, type(exc).__name__
    finally:
        if writer is not None:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass


async def run_load_async(args):
    sem = asyncio.Semaphore(args.concurrency)
    latencies = []
    errors = {}

    async def run_one():
        async with sem:
            ok, latency, error = await one_request(
                args.proxy_host,
                args.proxy_port,
                args.target_host,
                args.target_port,
                args.timeout,
            )
            if ok:
                latencies.append(latency)
            else:
                errors[error] = errors.get(error, 0) + 1
            return ok

    started = time.perf_counter()
    tasks = [asyncio.create_task(run_one()) for _ in range(args.count)]
    results = await asyncio.gather(*tasks)
    elapsed_ms = (time.perf_counter() - started) * 1000.0

    success = sum(1 for result in results if result)
    failures = args.count - success
    ordered = sorted(latencies)

    def percentile(p):
        if not ordered:
            return None
        index = min(len(ordered) - 1, int((len(ordered) - 1) * p))
        return round(ordered[index], 3)

    result = {
        "count": args.count,
        "concurrency": args.concurrency,
        "success": success,
        "failures": failures,
        "failure_rate": failures / args.count if args.count else 0,
        "elapsed_ms": round(elapsed_ms, 3),
        "rps": round(args.count / max(elapsed_ms / 1000.0, 0.001), 3),
        "p50_ms": percentile(0.50),
        "p95_ms": percentile(0.95),
        "p99_ms": percentile(0.99),
        "errors": errors,
    }

    text = json.dumps(result, sort_keys=True)
    print(text)
    if args.output:
        Path(args.output).write_text(text + "\n")


def run_load(args):
    asyncio.run(run_load_async(args))


def build_parser():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    server = subparsers.add_parser("server")
    server.add_argument("--root", required=True)
    server.add_argument("--host", default="127.0.0.1")
    server.add_argument("--nodes", type=int, default=8)
    server.add_argument("--target-port", type=int, default=18080)
    server.add_argument("--metrics-port", type=int, default=18081)
    server.add_argument("--proxy-base-port", type=int, default=18101)
    server.set_defaults(func=run_server)

    load = subparsers.add_parser("load")
    load.add_argument("--proxy-host", default="127.0.0.1")
    load.add_argument("--proxy-port", type=int, default=17890)
    load.add_argument("--target-host", default="127.0.0.1")
    load.add_argument("--target-port", type=int, default=18080)
    load.add_argument("--count", type=int, required=True)
    load.add_argument("--concurrency", type=int, required=True)
    load.add_argument("--timeout", type=float, default=5.0)
    load.add_argument("--output")
    load.set_defaults(func=run_load)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
