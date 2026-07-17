// Fork: pure state + keymap + status-bar logic for the interactive `cards --watch` TUI.
// Everything here is side-effect free so it can be unit-tested without a terminal.

import CodexBarCore
import Foundation

/// The distinct full-screen views the watch loop can show.
enum WatchViewKind: Equatable, Sendable {
    case cards
    case week
    case thirtyDays
    case heatmap

    var title: String {
        switch self {
        case .cards: "cards"
        case .week: "week"
        case .thirtyDays: "30d"
        case .heatmap: "heatmap"
        }
    }
}

/// Which view is showing plus whether the help overlay is up.
struct WatchViewState: Equatable, Sendable {
    var current: WatchViewKind = .cards
    var helpVisible: Bool = false
}

/// Result of interpreting a keystroke against the current view state.
enum WatchKeyOutcome: Equatable, Sendable {
    case quit
    case refresh
    case update(WatchViewState)
    case ignored
}

/// vim-style single-key bindings. Pressing a view key again toggles back to cards.
enum CLIWatchKeymap {
    static func handleKey(_ byte: UInt8, view: WatchViewState) -> WatchKeyOutcome {
        // While help is up, any key dismisses it (q/Ctrl-C still quit).
        if view.helpVisible {
            if byte == UInt8(ascii: "q") || byte == 0x03 {
                return .quit
            }
            var next = view
            next.helpVisible = false
            return .update(next)
        }

        switch byte {
        case UInt8(ascii: "q"), 0x03: // q or Ctrl-C
            return .quit
        case UInt8(ascii: "r"):
            return .refresh
        case UInt8(ascii: "?"):
            var next = view
            next.helpVisible = true
            return .update(next)
        case UInt8(ascii: "w"):
            return .update(WatchViewState(current: view.current == .week ? .cards : .week))
        case UInt8(ascii: "m"):
            return .update(WatchViewState(current: view.current == .thirtyDays ? .cards : .thirtyDays))
        case UInt8(ascii: "h"):
            return .update(WatchViewState(current: view.current == .heatmap ? .cards : .heatmap))
        case UInt8(ascii: "c"):
            return .update(WatchViewState(current: .cards))
        default:
            return .ignored
        }
    }
}

/// One completed refresh: the cards to render plus per-provider token history.
struct WatchPayload: Sendable {
    let cards: [CLICardModel]
    let failures: [CLICardFailure]
    /// Daily token entries per provider, already merged (SQLite history ∪ live snapshot).
    let dailyByProvider: [UsageProvider: [CostUsageDailyReport.Entry]]
    let fetchedAt: Date
    let duration: TimeInterval
}

/// Events feeding the single-consumer main loop.
enum WatchEvent: Sendable {
    case key(UInt8)
    case tick
    case refreshCompleted(WatchPayload)
    case refreshFailed(String)
    case resize
}

/// Mutable run state held by the main loop (never shared across tasks).
struct WatchDataCache {
    var latest: WatchPayload?
    var isFetching: Bool = false
    var fetchStartedAt: Date?
    var nextRefreshAt: Date?
    var lastError: String?
    var spinnerFrame: Int = 0
}

/// Snapshot of what the status bar needs to render one frame.
struct WatchStatusInfo {
    let view: WatchViewKind
    let isFetching: Bool
    let lastFetchedAt: Date?
    let lastDuration: TimeInterval?
    let secondsUntilRefresh: Int?
    let spinnerFrame: Int
    let lastError: String?
}

enum CLIWatchStatusBar {
    static let spinnerFrames: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    /// Renders the bottom status line, padded/truncated to `width` and (optionally) shown
    /// in reverse video. `timeFormatter` is injected so tests stay deterministic.
    static func render(
        info: WatchStatusInfo,
        width: Int,
        useColor: Bool,
        timeString: (Date) -> String) -> String
    {
        let keyHints = "w week · m 30d · h heatmap · r refresh · ? help · q quit"
        let viewTag = "[\(info.view.title)]"

        var middle = ""
        if let fetchedAt = info.lastFetchedAt {
            middle = "updated \(timeString(fetchedAt))"
            if let duration = info.lastDuration {
                middle += " (took \(Int(duration.rounded()))s)"
            }
        }

        var right = ""
        if info.isFetching {
            let frame = Self.spinnerFrames[info.spinnerFrame % Self.spinnerFrames.count]
            right = "\(frame) fetching…"
        } else if let seconds = info.secondsUntilRefresh {
            right = "next in \(max(0, seconds))s"
        }

        var segments = ["\(viewTag) \(keyHints)"]
        if !middle.isEmpty { segments.append(middle) }
        if !right.isEmpty { segments.append(right) }
        if let error = info.lastError, !error.isEmpty {
            segments.append("last fetch failed")
        }

        let text = " " + segments.joined(separator: "  │  ") + " "
        let padded = Self.fit(text, width: width)
        guard useColor else { return padded }
        return "\u{001B}[7m\(padded)\u{001B}[0m"
    }

    /// Pads with spaces or truncates (with an ellipsis) to exactly `width` visible columns.
    static func fit(_ text: String, width: Int) -> String {
        guard width > 0 else { return "" }
        let count = text.count
        if count == width { return text }
        if count < width { return text + String(repeating: " ", count: width - count) }
        if width == 1 { return "…" }
        return String(text.prefix(width - 1)) + "…"
    }
}

/// ANSI-aware width helpers shared by the watch renderers.
enum CLIWatchText {
    private enum WidthScanState { case plain, escape, csi }

    /// Visible column count, ignoring CSI escape sequences. Assumes width-1 glyphs
    /// (true for the ASCII + box-drawing + block characters the watch views use).
    static func visibleWidth(_ text: String) -> Int {
        var width = 0
        var state: WidthScanState = .plain
        for scalar in text.unicodeScalars {
            switch state {
            case .plain:
                if scalar.value == 0x1B {
                    state = .escape
                } else {
                    width += 1
                }
            case .escape:
                // ESC '[' starts a CSI sequence; any other byte is a short escape.
                state = scalar.value == 0x5B ? .csi : .plain
            case .csi:
                // Parameter/intermediate bytes are 0x20...0x3F; a final byte 0x40...0x7E ends it.
                if (0x40...0x7E).contains(scalar.value) {
                    state = .plain
                }
            }
        }
        return width
    }

    /// Right-pads `text` to `width` visible columns (no truncation).
    static func padVisible(_ text: String, to width: Int) -> String {
        let current = self.visibleWidth(text)
        guard current < width else { return text }
        return text + String(repeating: " ", count: width - current)
    }
}
