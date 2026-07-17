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

Usage:
    inject-subpath-fix.py [<www-dir> [<fix-html-path>]]

<www-dir> is the noVNC web root containing index.html + vnc.html; it defaults to
the KasmVNC .deb's install location. In the container-contribution model the
KasmVNC payload is extracted to a RELOCATABLE prefix in the *-editor image, so
the build passes the staged www dir explicitly (e.g.
/opt/che-android-studio/kasmvnc/usr/share/kasmvnc/www).
"""

import os
import sys

DEFAULT_WWW_DIR = "/usr/share/kasmvnc/www"
DEFAULT_FIX_PATH = "/usr/share/che-android-studio/kasmvnc-subpath-fix.html"
MARKER = '<script type="module"'
SENTINEL = "che-android-studio: sub-path websocket fix"


def main() -> int:
    www_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WWW_DIR
    fix_path = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_FIX_PATH
    targets = [os.path.join(www_dir, "index.html"), os.path.join(www_dir, "vnc.html")]

    with open(fix_path, encoding="utf-8") as fh:
        fix = fh.read()

    for path in targets:
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
