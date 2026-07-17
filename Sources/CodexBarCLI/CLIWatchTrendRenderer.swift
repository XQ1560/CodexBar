// Fork: terminal trend visualizations for the `cards --watch` TUI — weekly bar chart,
// 30-day mini bars, and a GitHub-style contribution heatmap. Pure string rendering.

import CodexBarCore
import Foundation

enum CLIWatchTrendRenderer {
    static let partialBlocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    static let emptyCellRGB = (r: 48, g: 50, b: 62)

    // Teal gradient shared with the card bars (bottom dark → top light).
    static let barDarkRGB = (r: 40, g: 150, b: 140)
    static let barLightRGB = (r: 90, g: 220, b: 200)

    // GitHub-ish green ramp for heatmap levels 1...4 (level 0 is the empty gray).
    static let heatLevelRGB: [(r: Int, g: Int, b: Int)] = [
        (14, 68, 41),
        (0, 109, 50),
        (38, 166, 65),
        (57, 211, 83),
    ]
    static let heatNoColorGlyph: [Character] = ["·", "░", "▒", "▓", "█"]

    // MARK: - Weekly bar chart

    /// A vertical bar chart with one column per weekday (Mon..Sun).
    static func renderWeek(
        title: String,
        slots: [CostUsageDaySlot],
        height: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        let barHeight = max(3, min(height, 12))
        let colWidth = 6
        let maxTokens = slots.compactMap(\.totalTokens).max() ?? 0
        var lines: [String] = [Self.styledTitle(title, useColor: useColor, enhanced: enhanced)]

        // Bar rows, top to bottom.
        let bars = slots.map { Self.verticalBar(value: $0.totalTokens ?? 0, max: maxTokens, height: barHeight) }
        for row in 0..<barHeight {
            var line = "  "
            for (index, bar) in bars.enumerated() {
                let glyph = bar[row]
                let fraction = Double(barHeight - row) / Double(barHeight)
                let cell = Self.colorizeBarGlyph(
                    glyph, fraction: fraction, isToday: slots[index].isToday,
                    useColor: useColor, enhanced: enhanced)
                line += Self.center(cell, glyphWidth: 1, columnWidth: colWidth)
            }
            lines.append(line)
        }

        // Axis + labels.
        lines.append("  " + String(repeating: "─", count: colWidth * slots.count))
        let weekdaySymbols = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        lines.append(Self.labelRow(slots.indices.map { weekdaySymbols[$0 % 7] }, columnWidth: colWidth,
                                   highlight: slots.map(\.isToday), useColor: useColor, enhanced: enhanced))
        lines.append(Self.labelRow(slots.map { Self.monthDay($0.dayKey) }, columnWidth: colWidth,
                                   highlight: slots.map { _ in false }, useColor: useColor, enhanced: enhanced))
        lines.append(Self.labelRow(slots.map { Self.tokenLabel($0.totalTokens) }, columnWidth: colWidth,
                                   highlight: slots.map { _ in false }, useColor: useColor, enhanced: enhanced))

        // Total goes in the title (survives truncation); the breakdown line follows the chart.
        let totals = CostUsageTokenTotals.from(slots: slots)
        lines[0] = Self.titleWithTotal(title, totals: totals, useColor: useColor, enhanced: enhanced)
        lines.append("")
        lines.append(Self.statsLine(totals, useColor: useColor, enhanced: enhanced))
        return lines
    }

    // MARK: - 30-day mini bars

    static func renderThirtyDays(
        title: String,
        slots: [CostUsageDaySlot],
        width: Int,
        height: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        var lines: [String] = [Self.styledTitle(title, useColor: useColor, enhanced: enhanced)]
        let maxTokens = slots.compactMap(\.totalTokens).max() ?? 0

        if width < 45 {
            // Narrow terminal: single-line sparkline.
            var spark = "  "
            for slot in slots {
                let glyph = Self.sparkGlyph(value: slot.totalTokens ?? 0, max: maxTokens)
                spark += Self.colorizeBarGlyph(
                    glyph, fraction: 1, isToday: slot.isToday, useColor: useColor, enhanced: enhanced)
            }
            lines.append(spark)
        } else {
            let barHeight = max(3, min(height, 10))
            let bars = slots.map { Self.verticalBar(value: $0.totalTokens ?? 0, max: maxTokens, height: barHeight) }
            for row in 0..<barHeight {
                var line = "  "
                for (index, bar) in bars.enumerated() {
                    let fraction = Double(barHeight - row) / Double(barHeight)
                    line += Self.colorizeBarGlyph(
                        bar[row], fraction: fraction, isToday: slots[index].isToday,
                        useColor: useColor, enhanced: enhanced)
                }
                lines.append(line)
            }
            lines.append("  " + String(repeating: "─", count: slots.count))
            // Date ticks every 7 columns (aligned under the bar row).
            var tick = "  "
            var index = 0
            while index < slots.count {
                if index % 7 == 0 {
                    let label = Self.monthDay(slots[index].dayKey)
                    tick += label
                    index += label.count
                } else {
                    tick += " "
                    index += 1
                }
            }
            lines.append(Self.subtle(tick, useColor: useColor, enhanced: enhanced))
        }

        let totals = CostUsageTokenTotals.from(slots: slots)
        lines[0] = Self.titleWithTotal(title, totals: totals, useColor: useColor, enhanced: enhanced)
        lines.append("")
        lines.append(Self.statsLine(totals, useColor: useColor, enhanced: enhanced))
        let peak = slots.max { ($0.totalTokens ?? 0) < ($1.totalTokens ?? 0) }
        if let peak, let peakTokens = peak.totalTokens, peakTokens > 0 {
            lines.append("  " + Self.subtle(
                "\(totals.activeDays) active days · peak \(Self.monthDay(peak.dayKey)) "
                    + "(\(UsageFormatter.tokenCountString(peakTokens)))",
                useColor: useColor, enhanced: enhanced))
        }
        return lines
    }

    // MARK: - GitHub-style heatmap

    /// `grid` is week-columns (oldest first), each a Mon..Sun array of 7 slots. When the
    /// terminal can't fit every week on one row, the weeks wrap into stacked 7-row bands
    /// instead of dropping older weeks.
    static func renderHeatmap(
        title: String,
        grid: [[CostUsageDaySlot]],
        width: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        let leftMargin = 4
        let cellWidth = 2
        let columnsPerBand = max(1, (width - leftMargin) / cellWidth)

        // Colour thresholds come from the whole grid so bands stay consistent.
        let allTokens = grid.flatMap { $0.compactMap(\.totalTokens) }
        let thresholds = Self.quantileThresholds(allTokens)
        let totals = CostUsageTokenTotals.from(slots: grid.flatMap { $0 })

        var lines: [String] = [Self.titleWithTotal(title, totals: totals, useColor: useColor, enhanced: enhanced)]

        let rowLabels = ["Mon", "   ", "Wed", "   ", "Fri", "   ", "Sun"]
        var start = 0
        var isFirstBand = true
        while start < grid.count {
            let band = Array(grid[start..<min(start + columnsPerBand, grid.count)])
            if !isFirstBand { lines.append("") }
            isFirstBand = false
            lines.append(Self.monthHeader(columns: band, leftMargin: leftMargin, cellWidth: cellWidth,
                                          useColor: useColor, enhanced: enhanced))
            for row in 0..<7 {
                var line = Self.subtle(rowLabels[row], useColor: useColor, enhanced: enhanced) + " "
                for column in band {
                    line += Self.heatCell(slot: column[row], thresholds: thresholds,
                                          useColor: useColor, enhanced: enhanced)
                }
                lines.append(line)
            }
            start += columnsPerBand
        }

        // Legend + breakdown + peak.
        lines.append("")
        lines.append(Self.heatLegend(useColor: useColor, enhanced: enhanced))
        lines.append(Self.statsLine(totals, useColor: useColor, enhanced: enhanced))
        let peak = grid.flatMap { $0 }.max { ($0.totalTokens ?? 0) < ($1.totalTokens ?? 0) }
        if let peak, let peakTokens = peak.totalTokens, peakTokens > 0 {
            lines.append("  " + Self.subtle(
                "\(totals.activeDays) active days · peak \(Self.monthDay(peak.dayKey)) "
                    + "(\(UsageFormatter.tokenCountString(peakTokens)))",
                useColor: useColor, enhanced: enhanced))
        } else {
            lines.append("  " + Self.subtle("\(totals.activeDays) active days", useColor: useColor, enhanced: enhanced))
        }
        return lines
    }

    // MARK: - Help overlay

    static func helpOverlayLines(interval: Int) -> [String] {
        [
            "┌─ codexbar watch ──────────────────┐",
            "│  (default)  cards view            │",
            "│  w          weekly token trend    │",
            "│  m          30-day token trend    │",
            "│  h          usage heatmap         │",
            "│  r          refresh now           │",
            "│  ?          toggle this help      │",
            "│  q / Ctrl-C quit                  │",
            "│                                   │",
            "│  interval: \(Self.pad("\(interval)s", 4)) · fetch ~30-50s │",
            "│  press any key to close           │",
            "└───────────────────────────────────┘",
        ]
    }

    // MARK: - Bars & glyphs

    /// Top-to-bottom column of `height` glyphs representing `value` scaled to `max`.
    static func verticalBar(value: Int, max maxValue: Int, height: Int) -> [Character] {
        guard height > 0 else { return [] }
        guard maxValue > 0, value > 0 else { return Array(repeating: " ", count: height) }
        let fraction = Swift.min(1.0, Double(value) / Double(maxValue))
        let eighths = Int((fraction * Double(height) * 8).rounded())
        var glyphs: [Character] = []
        for rowFromTop in 0..<height {
            let rowFromBottom = height - 1 - rowFromTop
            let cellStart = rowFromBottom * 8
            if eighths >= cellStart + 8 {
                glyphs.append("█")
            } else if eighths > cellStart {
                glyphs.append(Self.partialBlocks[Swift.min(7, eighths - cellStart - 1)])
            } else {
                glyphs.append(" ")
            }
        }
        return glyphs
    }

    static func sparkGlyph(value: Int, max maxValue: Int) -> Character {
        guard maxValue > 0, value > 0 else { return " " }
        let fraction = Swift.min(1.0, Double(value) / Double(maxValue))
        let index = Swift.max(0, Swift.min(7, Int((fraction * 8).rounded()) - 1))
        return Self.partialBlocks[index]
    }

    static func quantileThresholds(_ values: [Int]) -> [Int] {
        let nonzero = values.filter { $0 > 0 }.sorted()
        guard !nonzero.isEmpty else { return [] }
        func quantile(_ p: Double) -> Int {
            let index = Int((Double(nonzero.count - 1) * p).rounded(.down))
            return nonzero[Swift.max(0, Swift.min(nonzero.count - 1, index))]
        }
        return [quantile(0.25), quantile(0.5), quantile(0.75)]
    }

    static func heatLevel(for value: Int, thresholds: [Int]) -> Int {
        guard value > 0 else { return 0 }
        guard !thresholds.isEmpty else { return 1 }
        var level = 1
        for threshold in thresholds where value > threshold { level += 1 }
        return Swift.min(4, level)
    }

    // MARK: - Coloring helpers

    private static func colorizeBarGlyph(
        _ glyph: Character, fraction: Double, isToday: Bool,
        useColor: Bool, enhanced: Bool) -> String
    {
        let text = String(glyph)
        guard useColor, glyph != " " else { return text }
        if isToday {
            return CLIRenderer.colorizeEnhancedAccentBold(text)
        }
        guard enhanced else { return "\u{001B}[36m\(text)\u{001B}[0m" }
        let t = Swift.max(0, Swift.min(1, fraction))
        let r = Int(Double(Self.barDarkRGB.r) * (1 - t) + Double(Self.barLightRGB.r) * t)
        let g = Int(Double(Self.barDarkRGB.g) * (1 - t) + Double(Self.barLightRGB.g) * t)
        let b = Int(Double(Self.barDarkRGB.b) * (1 - t) + Double(Self.barLightRGB.b) * t)
        return CLIRenderer.ansiTrueColor(red: r, green: g, blue: b, text)
    }

    private static func heatCell(
        slot: CostUsageDaySlot, thresholds: [Int],
        useColor: Bool, enhanced: Bool) -> String
    {
        let level = slot.isFuture ? 0 : Self.heatLevel(for: slot.totalTokens ?? 0, thresholds: thresholds)
        guard useColor else {
            return "\(Self.heatNoColorGlyph[level]) "
        }
        let glyph = "■"
        if slot.isToday {
            return CLIRenderer.colorizeEnhancedAccentBold(glyph) + " "
        }
        if level == 0 {
            let c = Self.emptyCellRGB
            return CLIRenderer.ansiTrueColor(red: c.r, green: c.g, blue: c.b, glyph) + " "
        }
        guard enhanced else {
            return "\u{001B}[32m\(glyph)\u{001B}[0m "
        }
        let c = Self.heatLevelRGB[level - 1]
        return CLIRenderer.ansiTrueColor(red: c.r, green: c.g, blue: c.b, glyph) + " "
    }

    private static func heatLegend(useColor: Bool, enhanced: Bool) -> String {
        var cells = ""
        for level in 0...4 {
            let slot = CostUsageDaySlot(
                dayKey: "", date: Date(timeIntervalSince1970: 0),
                totalTokens: level == 0 ? 0 : level, costUSD: nil, isToday: false, isFuture: false)
            let thresholds = [1, 2, 3]
            cells += Self.heatCell(slot: slot, thresholds: thresholds, useColor: useColor, enhanced: enhanced)
        }
        let less = Self.subtle("Less ", useColor: useColor, enhanced: enhanced)
        let more = Self.subtle(" More", useColor: useColor, enhanced: enhanced)
        return "  " + less + cells + more
    }

    private static func monthHeader(
        columns: [[CostUsageDaySlot]], leftMargin: Int, cellWidth: Int,
        useColor: Bool, enhanced: Bool) -> String
    {
        var cells = Array(repeating: Character(" "), count: leftMargin + columns.count * cellWidth)
        var lastMonth = ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"
        for (index, column) in columns.enumerated() {
            let month = formatter.string(from: column[0].date)
            if month != lastMonth {
                lastMonth = month
                let start = leftMargin + index * cellWidth
                for (offset, character) in month.enumerated() where start + offset < cells.count {
                    cells[start + offset] = character
                }
            }
        }
        return Self.subtle(String(cells), useColor: useColor, enhanced: enhanced)
    }

    // MARK: - Text helpers

    private static func styledTitle(_ title: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return "  " + title }
        if enhanced { return "  " + CLIRenderer.colorizeEnhancedAccentBold(title) }
        return "  \u{001B}[1m\(title)\u{001B}[0m"
    }

    /// Title with the period total appended so it stays visible even if the body is truncated.
    private static func titleWithTotal(
        _ title: String, totals: CostUsageTokenTotals, useColor: Bool, enhanced: Bool) -> String
    {
        let suffix = totals.totalTokens > 0 ? " · \(UsageFormatter.tokenCountString(totals.totalTokens)) tokens" : ""
        return Self.styledTitle(title + suffix, useColor: useColor, enhanced: enhanced)
    }

    /// Input / output / cache-hit token breakdown plus cost.
    private static func statsLine(_ totals: CostUsageTokenTotals, useColor: Bool, enhanced: Bool) -> String {
        let parts = [
            "in \(UsageFormatter.tokenCountString(totals.inputTokens))",
            "out \(UsageFormatter.tokenCountString(totals.outputTokens))",
            "cache-hit \(UsageFormatter.tokenCountString(totals.cacheReadTokens))",
            "cache-write \(UsageFormatter.tokenCountString(totals.cacheCreationTokens))",
            "$\(String(format: "%.2f", totals.costUSD))",
        ]
        return "  " + Self.subtle(parts.joined(separator: " · "), useColor: useColor, enhanced: enhanced)
    }

    private static func subtle(_ text: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return text }
        if enhanced { return CLIRenderer.colorizeEnhancedSubtle(text) }
        return "\u{001B}[2m\(text)\u{001B}[0m"
    }

    private static func labelRow(
        _ labels: [String], columnWidth: Int, highlight: [Bool],
        useColor: Bool, enhanced: Bool) -> String
    {
        var line = "  "
        for (index, label) in labels.enumerated() {
            let centered = Self.center(label, glyphWidth: label.count, columnWidth: columnWidth)
            if useColor, index < highlight.count, highlight[index], enhanced {
                line += CLIRenderer.colorizeEnhancedAccentBold(centered)
            } else {
                line += centered
            }
        }
        return line
    }

    /// Centers `content` (whose visible glyph width is `glyphWidth`) in `columnWidth`.
    private static func center(_ content: String, glyphWidth: Int, columnWidth: Int) -> String {
        let clampedWidth = Swift.min(glyphWidth, columnWidth)
        let totalPad = Swift.max(0, columnWidth - clampedWidth)
        let leftPad = totalPad / 2
        let rightPad = totalPad - leftPad
        return String(repeating: " ", count: leftPad) + content + String(repeating: " ", count: rightPad)
    }

    private static func monthDay(_ dayKey: String) -> String {
        guard dayKey.count >= 10 else { return dayKey }
        return String(dayKey.dropFirst(5)) // "MM-dd"
    }

    private static func tokenLabel(_ tokens: Int?) -> String {
        guard let tokens, tokens > 0 else { return "—" }
        return UsageFormatter.tokenCountString(tokens)
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
