#!/usr/bin/env python3
"""Fork: pty smoke test for `codexbar cards --watch`.

Spawns the watch TUI on a pseudo-terminal, exercises the vim-style keys, and asserts
the terminal is set up and torn down cleanly. The first fetch is slow and may need
credentials, but the initial "Fetching usage…" frame renders immediately and keys work
during the fetch, so we can validate the TUI shell without waiting for real data.
"""
import os
import pty
import select
import sys
import time

BIN = sys.argv[1]

captured = bytearray()


def read_available(fd, timeout=0.6):
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if fd in r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            captured.extend(chunk)


def main():
    pid, fd = pty.fork()
    if pid == 0:  # child
        os.environ["TERM"] = "xterm-256color"
        os.environ["COLORTERM"] = "truecolor"
        os.execv(BIN, [BIN, "cards", "--watch", "--interval", "60", "--no-color"])
        os._exit(127)

    # parent
    read_available(fd, 1.2)          # initial frame
    for key in [b"w", b"m", b"h", b"?"]:
        os.write(fd, key)
        read_available(fd, 0.4)
    os.write(fd, b"q")               # quit
    read_available(fd, 1.0)

    try:
        os.close(fd)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)

    text = captured.decode("utf-8", "replace")
    checks = {
        "enters alternate screen": "\x1b[?1049h" in text,
        "hides cursor": "\x1b[?25l" in text,
        "renders first frame": "Fetching usage" in text or "week total" in text,
        "shows key hints": "q quit" in text,
        "week view tag": "[week]" in text,
        "help overlay": "codexbar watch" in text,
        "leaves alternate screen": "\x1b[?1049l" in text,
        "shows cursor again": "\x1b[?25h" in text,
        "child exited": os.WIFEXITED(status),
    }
    ok = all(checks.values())
    for name, passed in checks.items():
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
    print("RESULT:", "PASS" if ok else "FAIL", "| exit status:", status)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
