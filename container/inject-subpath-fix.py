#!/usr/bin/env python3
"""Inject the KasmVNC sub-path websocket fix into the noVNC HTML pages.

KasmVNC's noVNC client opens its websocket at the host ROOT
(wss://<host>/websockify), but Che serves the client under a per-workspace
sub-path (/developer/<ws>/6901/) and only routes the websocket there. So the
default root path fails ("can't connect to wss://host/websockify", gateway 418).
The fix (container/kasmvnc-subpath-fix.html) is an inline <script> that sets
noVNC's `path` setting from location.pathname before the client bundle loads.

This script inserts that snippet immediately before the module bundle
(`<script type="module" ...>`) in index.html + vnc.html. It lives in its own
file (rather than a Containerfile heredoc) because buildah's Dockerfile parser
rejects heredocs inside RUN instructions ("unterminated heredoc").

Idempotent: skips a file that already contains the fix marker.
"""

import sys

FIX_PATH = "/usr/share/che-android-studio/kasmvnc-subpath-fix.html"
TARGETS = [
    "/usr/share/kasmvnc/www/index.html",
    "/usr/share/kasmvnc/www/vnc.html",
]
MARKER = '<script type="module"'
SENTINEL = "che-android-studio: sub-path websocket fix"


def main() -> int:
    with open(FIX_PATH, encoding="utf-8") as fh:
        fix = fh.read()

    for path in TARGETS:
        with open(path, encoding="utf-8") as fh:
            html = fh.read()

        if SENTINEL in html:
            print(f"already patched: {path}")
            continue

        idx = html.find(MARKER)
        if idx == -1:
            print(f"ERROR: module script tag not found in {path}", file=sys.stderr)
            return 1

        html = html[:idx] + fix + html[idx:]
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(html)
        print(f"injected sub-path fix into {path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
