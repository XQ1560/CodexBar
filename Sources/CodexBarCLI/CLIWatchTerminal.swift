// Fork: raw-mode + alternate-screen management for the `cards --watch` TUI. restore()
// is idempotent and reachable from defer, atexit, and the signal handler, so a crash or
// Ctrl-C never leaves the terminal in raw mode.

import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// C entry point for atexit — restores the terminal if the process exits unexpectedly.
private func codexbarWatchRestoreAtExit() {
    CLIWatchTerminal.restore()
}

enum CLIWatchTerminal {
    nonisolated(unsafe) private static var savedTermios = termios()
    nonisolated(unsafe) private static var isRawActive = false
    nonisolated(unsafe) private static var atExitInstalled = false
    private static let lock = NSLock()

    /// True only when both stdin and stdout are attached to a terminal.
    static var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    /// Enters raw mode + the alternate screen and hides the cursor. Returns false if
    /// stdin's current attributes can't be read (not a tty).
    @discardableResult
    static func enter() -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard !Self.isRawActive else { return true }

        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else { return false }
        Self.savedTermios = current

        var raw = current
        // Turn off canonical mode and echo; keep ISIG so Ctrl-C still raises SIGINT and
        // flows through the shared signal handler (which restores the terminal).
        raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        raw.c_iflag &= ~(tcflag_t(ICRNL) | tcflag_t(IXON))
        Self.setControlChar(&raw, index: Int(VMIN), value: 1)
        Self.setControlChar(&raw, index: Int(VTIME), value: 0)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return false }

        Self.isRawActive = true
        if !Self.atExitInstalled {
            atexit(codexbarWatchRestoreAtExit)
            Self.atExitInstalled = true
        }
        // Enter alternate screen, hide cursor, clear.
        Self.write("\u{001B}[?1049h\u{001B}[?25l\u{001B}[2J\u{001B}[H")
        return true
    }

    /// Restores cooked mode, shows the cursor, and leaves the alternate screen.
    /// Safe to call multiple times and from a signal-source handler.
    static func restore() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard Self.isRawActive else { return }
        Self.isRawActive = false
        // Reset attributes, show cursor, leave alternate screen.
        Self.write("\u{001B}[0m\u{001B}[?25h\u{001B}[?1049l")
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &Self.savedTermios)
    }

    /// Current terminal size, falling back to 80x24 when the ioctl fails.
    static func size() -> (rows: Int, cols: Int) {
        var windowSize = winsize(ws_row: 0, ws_col: 0, ws_xpixel: 0, ws_ypixel: 0)
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &windowSize) == 0 else {
            return (24, 80)
        }
        let rows = Int(windowSize.ws_row)
        let cols = Int(windowSize.ws_col)
        return (rows > 0 ? rows : 24, cols > 0 ? cols : 80)
    }

    /// Writes a full frame: home cursor, then the payload. The caller is responsible for
    /// per-line erase (\e[K) and trailing \e[0J so stale content is cleared without a
    /// full-screen flush (which flickers).
    static func render(_ frame: String) {
        Self.write("\u{001B}[H" + frame)
    }

    // MARK: - Internals

    private static func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                posixWrite(STDOUT_FILENO, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written <= 0 { break }
            offset += written
        }
    }

    private static func setControlChar(_ term: inout termios, index: Int, value: UInt8) {
        withUnsafeMutablePointer(to: &term.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[index] = cc_t(value)
            }
        }
    }
}

// Platform write shim (POSIX write is spelled the same on all supported libcs).
@inline(__always)
private func posixWrite(_ fd: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Glibc)
    return Glibc.write(fd, buffer, count)
    #elseif canImport(Musl)
    return Musl.write(fd, buffer, count)
    #elseif canImport(Darwin)
    return Darwin.write(fd, buffer, count)
    #else
    return -1
    #endif
}
