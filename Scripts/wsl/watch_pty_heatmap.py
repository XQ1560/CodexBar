#!/usr/bin/env python3
"""Fork: pty check that `cards --watch` heatmap is a single combined graph.

Launches the watch TUI through the codexbar launcher (so it inherits the real env and
token data), switches to the heatmap view, waits for the first refresh to finish, then
asserts exactly one "usage heatmap" section is rendered.
"""
import os
import pty
import re
import select
import sys
import time

LAUNCHER = sys.argv[1]
captured = bytearray()


def pump(fd, seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            captured.extend(chunk)


def main():
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv("/bin/bash", ["/bin/bash", LAUNCHER, "cards", "--watch", "--no-color"])
        os._exit(127)

    pump(fd, 1.0)
    os.write(fd, b"h")            # switch to heatmap immediately
    # Wait for the first refresh to land (status bar shows "updated ..."), up to 75s.
    deadline = time.time() + 75
    while time.time() < deadline:
        pump(fd, 1.0)
        if "updated " in captured.decode("utf-8", "replace"):
            break
    os.write(fd, b"h")            # re-assert heatmap view after data arrives
    pump(fd, 1.5)
    os.write(fd, b"q")
    pump(fd, 1.0)
    try:
        os.close(fd)
    except OSError:
        pass
    os.waitpid(pid, 0)

    # Strip ANSI, keep the last full frame (after the final home-cursor).
    text = captured.decode("utf-8", "replace")
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", text)
    frames = plain.split("\x1b[H") if "\x1b[H" in plain else [plain]
    last = plain
    for frame in reversed(frames):
        if "usage heatmap" in frame or "No token history" in frame:
            last = frame
            break

    heatmap_titles = re.findall(r".*usage heatmap.*", last)
    count = len(heatmap_titles)
    print("--- last heatmap frame (trimmed) ---")
    for line in last.splitlines():
        if line.strip():
            print("   ", line.rstrip())
    print("--- checks ---")
    single = count == 1
    print(f"  heatmap sections found: {count} (expect 1)")
    for title in heatmap_titles:
        print(f"    title: {title.strip()}")
    print("RESULT:", "PASS" if single else "FAIL")
    sys.exit(0 if single else 1)


if __name__ == "__main__":
    main()
