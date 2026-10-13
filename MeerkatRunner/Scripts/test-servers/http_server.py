#!/usr/bin/env python3
"""Minimal HTTP server for SupervisorTests (AGENTS.md §10).

Usage: http_server.py [port] [--host HOST]
Prints the URL on startup so port learning from output can be tested too.
"""
import argparse
import http.server
import socketserver


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", nargs="?", type=int, default=0)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((args.host, args.port), http.server.SimpleHTTPRequestHandler) as httpd:
        port = httpd.server_address[1]
        print(f"Serving at http://localhost:{port}/", flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
