// Fork: event producers for the `cards --watch` TUI — a keyboard reader (poll+read on a
// dedicated thread so it never starves the Swift concurrency pool), a 1s ticker, and a
// SIGWINCH resize monitor. All feed WatchEvents into the main loop's AsyncStream.

import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// No-op capture handler so DispatchSource can observe SIGWINCH (mirrors the pattern in
/// CLITerminationSignalMonitor).
private func handleWatchWindowChange(_: Int32) {}

final class CLIWatchInput: @unchecked Sendable {
    private let keyboardThread: Thread
    private let tickerTask: Task<Void, Never>
    private let resizeSource: DispatchSourceSignal
    private let lock = NSLock()
    private var stopped = false

    init(yield: @escaping @Sendable (WatchEvent) -> Void) {
        // Keyboard: blocking poll+read on its own thread.
        let thread = Thread {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            while !Thread.current.isCancelled {
                descriptor.revents = 0
                let ready = poll(&descriptor, 1, 200)
                guard ready > 0, (descriptor.revents & Int16(POLLIN)) != 0 else { continue }
                var byte: UInt8 = 0
                let count = read(STDIN_FILENO, &byte, 1)
                if count == 1 {
                    yield(.key(byte))
                } else if count == 0 {
                    break // stdin closed
                }
            }
        }
        thread.name = "codexbar-watch-input"
        thread.stackSize = 1 << 16
        self.keyboardThread = thread

        // Ticker: 1s heartbeat drives the countdown and spinner.
        self.tickerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                yield(.tick)
            }
        }

        // Resize: SIGWINCH → .resize.
        _ = signalNoOp(SIGWINCH)
        let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global(qos: .utility))
        source.setEventHandler { yield(.resize) }
        self.resizeSource = source

        thread.start()
        source.resume()
    }

    func stop() {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.stopped else { return }
        self.stopped = true

        self.keyboardThread.cancel()
        self.tickerTask.cancel()
        self.resizeSource.cancel()
        restoreDefaultSignal(SIGWINCH)
    }

    deinit {
        self.stop()
    }
}

private func signalNoOp(_ number: Int32) -> Bool {
    #if canImport(Glibc)
    return Glibc.signal(number, handleWatchWindowChange) != nil
    #elseif canImport(Musl)
    return Musl.signal(number, handleWatchWindowChange) != nil
    #elseif canImport(Darwin)
    return Darwin.signal(number, handleWatchWindowChange) != nil
    #else
    return false
    #endif
}

private func restoreDefaultSignal(_ number: Int32) {
    #if canImport(Glibc)
    _ = Glibc.signal(number, SIG_DFL)
    #elseif canImport(Musl)
    _ = Musl.signal(number, SIG_DFL)
    #elseif canImport(Darwin)
    _ = Darwin.signal(number, SIG_DFL)
    #endif
}
