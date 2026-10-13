#!/usr/bin/env python3
"""Listener that ignores SIGTERM, so the supervisor must SIGKILL it after 5 s (AGENTS.md §10).

Usage: ignore_sigterm.py [port]
"""
import signal
import socket
import sys
import time


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("127.0.0.1", port))
    sock.listen()
    print(f"Listening on http://localhost:{sock.getsockname()[1]}/ (ignoring SIGTERM)", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
