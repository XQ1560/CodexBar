import Foundation
import Testing
@testable import CodexBarCLI

#if os(Linux)
struct CLIWatchStateTests {
    private func key(_ character: Character) -> UInt8 { character.asciiValue! }

    @Test
    func `q and Ctrl-C quit`() {
        #expect(CLIWatchKeymap.handleKey(self.key("q"), view: WatchViewState()) == .quit)
        #expect(CLIWatchKeymap.handleKey(0x03, view: WatchViewState()) == .quit)
    }

    @Test
    func `r refreshes`() {
        #expect(CLIWatchKeymap.handleKey(self.key("r"), view: WatchViewState()) == .refresh)
    }

    @Test
    func `view keys switch to their view`() {
        #expect(CLIWatchKeymap.handleKey(self.key("w"), view: WatchViewState())
            == .update(WatchViewState(current: .week)))
        #expect(CLIWatchKeymap.handleKey(self.key("m"), view: WatchViewState())
            == .update(WatchViewState(current: .thirtyDays)))
        #expect(CLIWatchKeymap.handleKey(self.key("h"), view: WatchViewState())
            == .update(WatchViewState(current: .heatmap)))
    }

    @Test
    func `pressing the active view key toggles back to cards`() {
        #expect(CLIWatchKeymap.handleKey(self.key("w"), view: WatchViewState(current: .week))
            == .update(WatchViewState(current: .cards)))
        #expect(CLIWatchKeymap.handleKey(self.key("h"), view: WatchViewState(current: .heatmap))
            == .update(WatchViewState(current: .cards)))
    }

    @Test
    func `question mark toggles help and any key closes it`() {
        let opened = CLIWatchKeymap.handleKey(self.key("?"), view: WatchViewState(current: .week))
        #expect(opened == .update(WatchViewState(current: .week, helpVisible: true)))

        let helpState = WatchViewState(current: .week, helpVisible: true)
        #expect(CLIWatchKeymap.handleKey(self.key("x"), view: helpState)
            == .update(WatchViewState(current: .week, helpVisible: false)))
        // q still quits from help.
        #expect(CLIWatchKeymap.handleKey(self.key("q"), view: helpState) == .quit)
    }

    @Test
    func `unmapped keys are ignored`() {
        #expect(CLIWatchKeymap.handleKey(self.key("z"), view: WatchViewState()) == .ignored)
    }

    @Test
    func `status bar shows view tag and key hints`() {
        let info = WatchStatusInfo(
            view: .cards, isFetching: false, lastFetchedAt: nil, lastDuration: nil,
            secondsUntilRefresh: 42, spinnerFrame: 0, lastError: nil, monthDays: 15)
        let bar = CLIWatchStatusBar.render(info: info, width: 120, useColor: false, timeString: { _ in "12:00:00" })
        #expect(bar.contains("[cards]"))
        #expect(bar.contains("w week"))
        #expect(bar.contains("q quit"))
        #expect(bar.contains("next in 42s"))
        #expect(bar.count == 120)
    }

    @Test
    func `status bar shows spinner while fetching`() {
        let info = WatchStatusInfo(
            view: .week, isFetching: true, lastFetchedAt: nil, lastDuration: nil,
            secondsUntilRefresh: nil, spinnerFrame: 2, lastError: nil, monthDays: 15)
        let bar = CLIWatchStatusBar.render(info: info, width: 120, useColor: false, timeString: { _ in "12:00:00" })
        #expect(bar.contains("[week]"))
        #expect(bar.contains("fetching…"))
        #expect(bar.contains("⠹"))
    }

    @Test
    func `status bar reports the last error`() {
        let info = WatchStatusInfo(
            view: .cards, isFetching: false, lastFetchedAt: Date(timeIntervalSince1970: 0),
            lastDuration: 38, secondsUntilRefresh: 10, spinnerFrame: 0, lastError: "boom", monthDays: 15)
        let bar = CLIWatchStatusBar.render(info: info, width: 160, useColor: false, timeString: { _ in "12:00:00" })
        #expect(bar.contains("updated 12:00:00 (took 38s)"))
        #expect(bar.contains("last fetch failed"))
    }

    @Test
    func `status bar truncates to width`() {
        let info = WatchStatusInfo(
            view: .cards, isFetching: false, lastFetchedAt: nil, lastDuration: nil,
            secondsUntilRefresh: 5, spinnerFrame: 0, lastError: nil, monthDays: 15)
        let bar = CLIWatchStatusBar.render(info: info, width: 20, useColor: false, timeString: { _ in "12:00:00" })
        #expect(bar.count == 20)
        #expect(bar.hasSuffix("…"))
    }

    @Test
    func `visible width ignores ansi escapes`() {
        let colored = "\u{001B}[38;2;40;150;140m█\u{001B}[0m"
        #expect(CLIWatchText.visibleWidth(colored) == 1)
        #expect(CLIWatchText.visibleWidth("abc") == 3)
    }

    @Test
    func `month view tag reflects the configured day count`() {
        // 15-day month view → tag [15d] and key hint "m 15d".
        let info15 = WatchStatusInfo(
            view: .thirtyDays, isFetching: false, lastFetchedAt: nil, lastDuration: nil,
            secondsUntilRefresh: 42, spinnerFrame: 0, lastError: nil, monthDays: 15)
        let bar15 = CLIWatchStatusBar.render(info: info15, width: 120, useColor: false, timeString: { _ in "12:00:00" })
        #expect(bar15.contains("[15d]"))
        #expect(bar15.contains("m 15d"))

        // A 30-day month view → tag [30d].
        let info30 = WatchStatusInfo(
            view: .thirtyDays, isFetching: false, lastFetchedAt: nil, lastDuration: nil,
            secondsUntilRefresh: 42, spinnerFrame: 0, lastError: nil, monthDays: 30)
        let bar30 = CLIWatchStatusBar.render(info: info30, width: 120, useColor: false, timeString: { _ in "12:00:00" })
        #expect(bar30.contains("[30d]"))
        #expect(bar30.contains("m 30d"))
    }
}
#endif
