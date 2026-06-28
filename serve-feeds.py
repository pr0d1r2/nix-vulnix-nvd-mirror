#!/usr/bin/env python3
"""Loopback feed server for the nvd-cache build (SPEC §V.46, §V.48).

vulnix is HTTP-only (no file:// adapter) and aborts its whole update on any
404 (raise_for_status) while requesting a date-derived year set
current-5..current. We therefore serve the local feed farm over loopback and,
for any requested ``nvdcve-2.0-<year|modified>.json.gz`` that the farm does not
contain, return a synthetic *empty-but-valid* feed (HTTP 200) instead of 404 —
making the build immune to the build-date vs feeds.lock-snapshot skew at year
rollover.

Usage: serve-feeds.py <feed-dir> <port>
"""
import gzip
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FEED_DIR = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2])

# nvdcve-2.0-2027.json.gz  or  nvdcve-2.0-modified.json.gz
FEED_RE = re.compile(r"^/nvdcve-2\.0-(\d{4}|modified)\.json\.gz$")

EMPTY_FEED = gzip.compress(
    json.dumps(
        {
            "resultsPerPage": 0,
            "startIndex": 0,
            "totalResults": 0,
            "format": "NVD_CVE",
            "version": "2.0",
            "vulnerabilities": [],
        }
    ).encode(),
    mtime=0,  # deterministic, no header timestamp
)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        m = FEED_RE.match(self.path)
        if not m:
            self._send(404, b"")
            return
        path = os.path.join(FEED_DIR, os.path.basename(self.path))
        if os.path.exists(path):  # real feed in the farm (follows symlinks)
            with open(path, "rb") as fh:
                self._send(200, fh.read())
        else:  # absent in-range year -> synthetic empty feed (§V.48)
            self._send(200, EMPTY_FEED)

    def log_message(self, *_):  # quiet
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
