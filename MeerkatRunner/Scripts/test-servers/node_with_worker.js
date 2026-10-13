#!/usr/bin/env node
// HTTP server that forks a child worker, so tests can verify stop kills the whole group (AGENTS.md §10).
// Usage: node node_with_worker.js [port]
'use strict';

const { fork } = require('node:child_process');
const http = require('node:http');

if (process.argv[2] === '--worker') {
  // Child: stay alive and report our PID so the test can check it was killed.
  console.log(`worker pid ${process.pid}`);
  setInterval(() => {}, 1 << 30);
} else {
  const port = Number(process.argv[2] || 0);
  const worker = fork(__filename, ['--worker']);
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(`ok (worker ${worker.pid})\n`);
  });
  server.listen(port, '127.0.0.1', () => {
    console.log(`Listening on http://localhost:${server.address().port}/`);
  });
}
