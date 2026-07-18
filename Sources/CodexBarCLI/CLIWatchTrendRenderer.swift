// Fork: terminal trend visualizations for the `cards --watch` TUI — weekly bar chart,
// 30-day mini bars, and a GitHub-style contribution heatmap. Pure string rendering.

import CodexBarCore
import Foundation

enum CLIWatchTrendRenderer {
    static let partialBlocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    // Fork: empty heatmap cell — a navy one step lighter than the terminal background so
    // the grid stays visible without competing with filled cells (card theme family).
    static let emptyCellRGB = (r: 29, g: 35, b: 54)

    // Teal gradient shared with the card bars (bottom dark → top light).
    static let barDarkRGB = (r: 40, g: 150, b: 140)
    static let barLightRGB = (r: 90, g: 220, b: 200)

    static let heatNoColorGlyph: [Character] = ["·", "░", "▒", "▓", "█"]

    /// Fork: minimum terminal width for the full-width card frame around trend views.
    /// Below this the views render unframed so tiny terminals keep every column.
    static let frameMinWidth = 40

    // MARK: - Weekly grouped bar chart

    /// A vertical bar chart with one column per weekday (Mon..Sun). Each day's column holds
    /// N thin side-by-side bars — one per provider — so different providers stay comparable
    /// instead of collapsing into a single stacked band. Every bar shares one global max,
    /// so bar height always reflects the true token volume across providers.
    static func renderWeek(
        title: String,
        badge: String = "",
        slots: [CostUsageStackedDaySlot],
        totals: [CostUsageStackedProviderTotals],
        height: Int,
        width: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        let framed = width >= Self.frameMinWidth
        let contentWidth = framed ? width - 4 : width
        let barHeight = max(3, min(height, 12))
        let providers = totals.map(\.provider)
        let palette = Self.providerPalette(for: providers)
        let maxValue = Self.globalMax(slots: slots)
        // Fork: fill the terminal width — bars within a day touch, the leftover width
        // grows the day gap so labels (date/total) get room and the chart spans the row.
        let layout = Self.groupedBarLayoutFilling(
            providerCount: providers.count, dayCount: slots.count, width: contentWidth)

        let grandTotals = CostUsageTokenTotals.from(slots: slots.map(\.asDaySlot))
        var lines: [String] = [Self.headerLine(
            title: title, badge: badge, totals: grandTotals,
            contentWidth: contentWidth, useColor: useColor, enhanced: enhanced)]
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))
        lines.append(contentsOf: Self.renderBandRows(
            slots: slots, providers: providers, maxValue: maxValue, palette: palette,
            height: barHeight, layout: layout, useColor: useColor, enhanced: enhanced,
            topLabel: { index, _ in
                let weekdaySymbols = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
                return weekdaySymbols[index % 7]
            }))
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))
        lines.append(contentsOf: Self.providerLegend(
            totals: totals, palette: palette, useColor: useColor, enhanced: enhanced))
        lines.append(Self.statsLine(grandTotals, useColor: useColor, enhanced: enhanced))
        let peak = slots.max { $0.grandTotal < $1.grandTotal }
        if let peak, peak.grandTotal > 0 {
            lines.append("  " + Self.subtle(
                "\(grandTotals.activeDays) active days · peak \(Self.monthDay(peak.dayKey)) "
                    + "(\(UsageFormatter.tokenCountString(peak.grandTotal)))",
                useColor: useColor, enhanced: enhanced))
        }
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))
        lines.append(contentsOf: Self.modelBreakdownTable(
            totals: totals, palette: palette, useColor: useColor, enhanced: enhanced))
        return framed
            ? Self.cardFrame(lines, width: width, useColor: useColor, enhanced: enhanced)
            : lines
    }

    // MARK: - 30-day grouped bars

    /// Fork: 15-day view mirrors the week view's front end exactly (same grouped layout,
    /// full day gap, axis, date/total label rows). When all days don't fit one row at the
    /// current terminal width, days wrap into stacked bands instead of collapsing to a
    /// sparkline or compressing the day gap — so every band looks identical to the week
    /// view. `topLabel` is the per-day header (date for this view).
    static func renderThirtyDays(
        title: String,
        badge: String = "",
        slots: [CostUsageStackedDaySlot],
        totals: [CostUsageStackedProviderTotals],
        width: Int,
        height: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        let framed = width >= Self.frameMinWidth
        let contentWidth = framed ? width - 4 : width
        let providers = totals.map(\.provider)
        let palette = Self.providerPalette(for: providers)
        let maxValue = Self.globalMax(slots: slots)
        let barHeight = max(3, min(height, 10))
        let baseLayout = Self.groupedBarLayout(providerCount: providers.count, compactDayGap: false)

        let grandTotals = CostUsageTokenTotals.from(slots: slots.map(\.asDaySlot))
        var lines: [String] = [Self.headerLine(
            title: title, badge: badge, totals: grandTotals,
            contentWidth: contentWidth, useColor: useColor, enhanced: enhanced)]
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))

        // Fork: split into bands using the minimum dayWidth, then fill each band's width by
        // growing its day gap. This keeps every band identical to the week view while
        // making the chart span the terminal and giving labels room.
        let daysPerBand = Self.daysPerBand(dayWidth: baseLayout.dayWidth, width: contentWidth, dayCount: slots.count)
        var startIndex = 0
        var bandIndex = 0
        while startIndex < slots.count {
            let endIndex = min(startIndex + daysPerBand, slots.count)
            let bandSlots = Array(slots[startIndex..<endIndex])
            let bandLayout = Self.groupedBarLayoutFilling(
                providerCount: providers.count, dayCount: bandSlots.count, width: contentWidth)
            if bandIndex > 0 { lines.append("") }
            lines.append(contentsOf: Self.renderBandRows(
                slots: bandSlots, providers: providers, maxValue: maxValue, palette: palette,
                height: barHeight, layout: bandLayout, useColor: useColor, enhanced: enhanced,
                topLabel: { _, slot in Self.monthDay(slot.dayKey) }, showDateRow: false))
            startIndex = endIndex
            bandIndex += 1
        }

        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))
        lines.append(contentsOf: Self.providerLegend(
            totals: totals, palette: palette, useColor: useColor, enhanced: enhanced))
        lines.append(Self.statsLine(grandTotals, useColor: useColor, enhanced: enhanced))
        let peak = slots.max { $0.grandTotal < $1.grandTotal }
        if let peak, peak.grandTotal > 0 {
            lines.append("  " + Self.subtle(
                "\(grandTotals.activeDays) active days · peak \(Self.monthDay(peak.dayKey)) "
                    + "(\(UsageFormatter.tokenCountString(peak.grandTotal)))",
                useColor: useColor, enhanced: enhanced))
        }
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))
        lines.append(contentsOf: Self.modelBreakdownTable(
            totals: totals, palette: palette, useColor: useColor, enhanced: enhanced))
        return framed
            ? Self.cardFrame(lines, width: width, useColor: useColor, enhanced: enhanced)
            : lines
    }

    /// Fork: days per band for the wrapped 15-day view. Prefers one band (all days) when
    /// it fits; otherwise picks the largest band that fits the terminal width, with a
    /// minimum of 5 so a band still reads as a chart.
    static func daysPerBand(dayWidth: Int, width: Int, dayCount: Int) -> Int {
        let usable = max(1, width - 2) // 2-column left indent on every bar row
        let fit = max(1, usable / max(1, dayWidth))
        if fit >= dayCount { return dayCount }
        return max(5, fit)
    }

    // MARK: - Shared grouped-bar renderer

    /// Renders one band of the grouped bar chart: the bar grid (one grouped column per day
    /// with a full-bar-width gap between days), the axis, and the label rows. Pure block —
    /// no title, stats, legend, or breakdown. Used by both the week view (single band) and
    /// the 15-day view (multiple wrapped bands).
    ///
    /// Label rows: week shows weekday + date + total (3 rows); the 15-day view sets
    /// `topLabel` to the date already, so `showDateRow: false` skips the duplicate date
    /// row and renders only topLabel (date) + total (2 rows).
    private static func renderBandRows(
        slots: [CostUsageStackedDaySlot],
        providers: [UsageProvider],
        maxValue: Int,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        height: Int,
        layout: GroupedBarLayout,
        useColor: Bool,
        enhanced: Bool,
        topLabel: (Int, CostUsageStackedDaySlot) -> String,
        showDateRow: Bool = true) -> [String]
    {
        var lines: [String] = []
        let dayColumns = slots.map { slot in
            Self.groupedDayColumn(
                slot: slot, providers: providers, maxValue: maxValue, palette: palette,
                height: height, layout: layout, useColor: useColor, enhanced: enhanced)
        }
        for row in 0..<height {
            var line = "  "
            for column in dayColumns {
                line += column[row]
            }
            lines.append(line)
        }

        // Axis + labels: one centered label per day (spans the day's grouped width).
        let dayWidth = layout.dayWidth
        lines.append("  " + String(repeating: "─", count: dayWidth * slots.count))
        lines.append(Self.labelRow(
            slots.indices.map { topLabel($0, slots[$0]) }, columnWidth: dayWidth,
            highlight: slots.map(\.isToday), useColor: useColor, enhanced: enhanced))
        // The 15-day view already shows the date as the top label — skip the duplicate row.
        if showDateRow {
            lines.append(Self.labelRow(slots.map { Self.monthDay($0.dayKey) }, columnWidth: dayWidth,
                                       highlight: slots.map { _ in false }, useColor: useColor, enhanced: enhanced))
        }
        lines.append(Self.labelRow(slots.map { Self.tokenLabel($0.grandTotal) }, columnWidth: dayWidth,
                                   highlight: slots.map { _ in false }, useColor: useColor, enhanced: enhanced))
        return lines
    }

    // MARK: - GitHub-style heatmap

    /// `grid` is week-columns (oldest first), each a Mon..Sun array of 7 slots. When the
    /// terminal can't fit every week on one row, the weeks wrap into stacked 7-row bands
    /// instead of dropping older weeks.
    static func renderHeatmap(
        title: String,
        badge: String = "",
        providersLabel: String = "",
        grid: [[CostUsageDaySlot]],
        width: Int,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        let framed = width >= Self.frameMinWidth
        let contentWidth = framed ? width - 4 : width
        // 2-column indent (matching every other section) + 4-column weekday label margin.
        let indent = framed ? "  " : ""
        let leftMargin = 4 + indent.count
        let cellWidth = 2
        let columnsPerBand = max(1, (contentWidth - leftMargin) / cellWidth)

        // Colour thresholds come from the whole grid so bands stay consistent.
        let allTokens = grid.flatMap { $0.compactMap(\.totalTokens) }
        let thresholds = Self.quantileThresholds(allTokens)
        let totals = CostUsageTokenTotals.from(slots: grid.flatMap { $0 })

        var lines: [String] = [Self.headerLine(
            title: title, badge: badge, totals: totals,
            contentWidth: contentWidth, useColor: useColor, enhanced: enhanced)]
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))

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
                var line = indent + Self.subtle(rowLabels[row], useColor: useColor, enhanced: enhanced) + " "
                for column in band {
                    line += Self.heatCell(slot: column[row], thresholds: thresholds,
                                          useColor: useColor, enhanced: enhanced)
                }
                lines.append(line)
            }
            start += columnsPerBand
        }

        // Legend + breakdown + peak.
        lines.append(Self.separatorLine(contentWidth: contentWidth, useColor: useColor, enhanced: enhanced))
        lines.append(Self.heatLegend(useColor: useColor, enhanced: enhanced))
        lines.append(Self.statsLine(totals, prefix: providersLabel, useColor: useColor, enhanced: enhanced))
        let peak = grid.flatMap { $0 }.max { ($0.totalTokens ?? 0) < ($1.totalTokens ?? 0) }
        if let peak, let peakTokens = peak.totalTokens, peakTokens > 0 {
            lines.append("  " + Self.subtle(
                "\(totals.activeDays) active days · peak \(Self.monthDay(peak.dayKey)) "
                    + "(\(UsageFormatter.tokenCountString(peakTokens)))",
                useColor: useColor, enhanced: enhanced))
        } else {
            lines.append("  " + Self.subtle("\(totals.activeDays) active days", useColor: useColor, enhanced: enhanced))
        }
        return framed
            ? Self.cardFrame(lines, width: width, useColor: useColor, enhanced: enhanced)
            : lines
    }

    // MARK: - Help overlay

    static func helpOverlayLines(interval: Int) -> [String] {
        // Rounded corners to match the card frame (card mode's ╭╮╰╯ vocabulary).
        [
            "╭─ codexbar watch ──────────────────╮",
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
            "╰───────────────────────────────────╯",
        ]
    }

    // MARK: - Fork: unified card frame + header (card mode's visual language)

    /// Wraps content lines in the card mode's rounded full-width frame. Lines longer than
    /// the inner width are truncated (ANSI-aware) so the right border stays aligned.
    static func cardFrame(_ content: [String], width: Int, useColor: Bool, enhanced: Bool) -> [String] {
        let innerWidth = max(1, width - 4)
        let horizontal = String(repeating: "─", count: max(0, width - 2))
        let side = Self.borderText("│", useColor: useColor, enhanced: enhanced)
        var lines = [Self.borderText("╭" + horizontal + "╮", useColor: useColor, enhanced: enhanced)]
        for line in content {
            let fitted = CLIWatchText.truncateVisible(line, to: innerWidth)
            lines.append(side + " " + CLIWatchText.padVisible(fitted, to: innerWidth) + " " + side)
        }
        lines.append(Self.borderText("╰" + horizontal + "╯", useColor: useColor, enhanced: enhanced))
        return lines
    }

    /// Card-style view header: bold accent title + badge pill on the left, gold period
    /// total right-aligned — the trend-view analogue of the provider card's header row.
    static func headerLine(
        title: String, badge: String, totals: CostUsageTokenTotals,
        contentWidth: Int, useColor: Bool, enhanced: Bool) -> String
    {
        var left = "  " + Self.styledTitle(title, useColor: useColor, enhanced: enhanced)
        if !badge.isEmpty {
            left += " " + Self.badgeText(badge, useColor: useColor, enhanced: enhanced)
        }
        guard totals.totalTokens > 0 else { return left }
        let tokens = UsageFormatter.tokenCountString(totals.totalTokens)
        let right = Self.subtle("TOTAL ", useColor: useColor, enhanced: enhanced)
            + Self.gold(tokens, useColor: useColor, enhanced: enhanced)
            + Self.subtle(" tokens", useColor: useColor, enhanced: enhanced)
        let gap = contentWidth - 2 - CLIWatchText.visibleWidth(left) - CLIWatchText.visibleWidth(right)
        guard gap >= 1 else { return left + " " + right }
        return left + String(repeating: " ", count: gap) + right
    }

    /// Full-width `─` rule inside the card, matching the card mode's section separator.
    static func separatorLine(contentWidth: Int, useColor: Bool, enhanced: Bool) -> String {
        "  " + Self.borderText(String(repeating: "─", count: max(1, contentWidth - 4)),
                               useColor: useColor, enhanced: enhanced)
    }

    private static func borderText(_ text: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return text }
        return enhanced ? CLIRenderer.colorizeEnhancedBorder(text) : CLIRenderer.colorizeCardBorder(text)
    }

    private static func badgeText(_ badge: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return "[\(badge)]" }
        return enhanced ? CLIRenderer.colorizeEnhancedBadge(badge) : CLIRenderer.colorizeCardBadge(badge)
    }

    private static func gold(_ text: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return text }
        return enhanced ? CLIRenderer.colorizeEnhancedPlanValue(text) : CLIRenderer.colorizeWarning(text)
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

    // MARK: - Fork: stacked bars + provider palette

    /// Fork: unified provider palette derived from the card enhanced theme. The first
    /// slots reuse the card's own hues (healthy-bar teal, badge blue, plan gold, the
    /// <10% rose and <50% orange warning tones); the rest are same-family derivatives.
    /// Purple is deliberately absent — it stays reserved for the today highlight.
    /// Index by provider order so the same provider keeps its color across frames.
    static let providerPaletteRGB: [(r: Int, g: Int, b: Int)] = [
        (90, 220, 200),   // teal       (= card healthy-bar light end)
        (111, 168, 245),  // blue       (badge-blue family)
        (238, 184, 92),   // gold       (= card PLAN value)
        (255, 95, 95),    // rose       (= card <10% light end)
        (255, 190, 90),   // orange     (= card <50% light end)
        (150, 230, 180),  // seafoam    (teal derivative)
        (170, 190, 250),  // periwinkle (blue derivative)
        (230, 205, 150),  // sand       (gold derivative)
        (250, 150, 150),  // blush      (rose derivative)
        (140, 200, 230),  // sky        (teal/blue derivative)
        (216, 162, 92),   // bronze
        (150, 175, 205),  // slate
    ]

    /// Fallback color when a provider has no palette slot.
    static let providerFallbackRGB = (r: 130, g: 135, b: 150)

    /// Maps each provider to a stable RGB triple. The first N providers (in the order the
    /// trend window sees them) get distinct colors; extras share the fallback.
    static func providerPalette(for providers: [UsageProvider]) -> [UsageProvider: (r: Int, g: Int, b: Int)] {
        var palette: [UsageProvider: (r: Int, g: Int, b: Int)] = [:]
        for (index, provider) in providers.enumerated() {
            if index < Self.providerPaletteRGB.count {
                palette[provider] = Self.providerPaletteRGB[index]
            } else {
                palette[provider] = Self.providerFallbackRGB
            }
        }
        return palette
    }

    // MARK: - Fork: grouped (side-by-side) bars

    /// Layout for a day's grouped column: N thin bars (one per provider) with a gap
    /// between days wide enough to read as a clear column separator. `dayWidth` = total
    /// columns one day occupies on screen (bars + inner gap + trailing day gap).
    struct GroupedBarLayout: Equatable {
        let providerCount: Int
        let barWidth: Int       // columns per provider bar (>= 1)
        let innerGap: Int       // columns between bars inside a day
        let dayGap: Int         // columns between days (trailing, after every day)
        var dayWidth: Int {
            let bars = providerCount * barWidth
            let gaps = providerCount > 1 ? innerGap * (providerCount - 1) : 0
            return bars + gaps + dayGap
        }
    }

    /// Picks a grouped layout. Each provider gets a 1-column bar; bars within a day are
    /// touching (innerGap 0) so the day reads as one tight multi-color block.
    /// `compactDayGap: true` drops the day gap entirely (used when wrapping would
    /// otherwise leave too few days per band).
    static func groupedBarLayout(providerCount: Int, compactDayGap: Bool = false) -> GroupedBarLayout {
        let count = max(1, providerCount)
        // Fork: innerGap 0 — bars within a day touch. Different providers are told apart
        // by color, not by a gap (a gap made each day look loose no matter how small).
        let innerGap = 0
        let dayGap = compactDayGap ? 0 : Self.defaultDayGap
        return GroupedBarLayout(
            providerCount: count, barWidth: 1, innerGap: innerGap, dayGap: dayGap)
    }

    /// Fork: builds a layout that fills the available terminal width by growing the day
    /// gap. Bars within a day stay touching (innerGap 0 — the "0.1"-equivalent: as tight
    /// as a character grid allows); the leftover width is distributed across the day gaps
    /// so the chart spans the whole terminal and the per-day label column (`dayWidth`)
    /// grows wide enough to hold date/total labels without crowding. Day gap is clamped to
    /// a sane maximum so a tiny day count doesn't stretch absurdly.
    static func groupedBarLayoutFilling(
        providerCount: Int, dayCount: Int, width: Int,
        compactDayGap: Bool = false) -> GroupedBarLayout
    {
        let base = Self.groupedBarLayout(providerCount: providerCount, compactDayGap: compactDayGap)
        guard dayCount > 0, width > 2 else { return base }
        let usable = width - 2 // 2-column left indent
        // Width one day occupies without any day gap (bars + inner gaps only).
        let barsWidth = base.providerCount * base.barWidth
            + (base.providerCount > 1 ? base.innerGap * (base.providerCount - 1) : 0)
        // Total gap budget = usable - (all day bar widths), spread across dayCount gaps.
        let gapBudget = usable - dayCount * barsWidth
        if gapBudget <= 0 { return base }
        let dayGap = min(Self.maxDayGap, gapBudget / dayCount)
        return GroupedBarLayout(
            providerCount: base.providerCount, barWidth: base.barWidth,
            innerGap: base.innerGap, dayGap: max(base.dayGap, dayGap))
    }

    /// Fork: day-gap bounds. The default is the minimum that keeps adjacent bars readable
    /// when the chart can't fill the terminal; the fill layout grows it up to the max.
    static let defaultDayGap = 2
    static let maxDayGap = 8

    /// Fork: the single global peak across every provider and every day in the window.
    /// All bars share this scale so a tall bar always means more tokens, regardless of
    /// which provider it belongs to (no per-provider renormalization that would hide
    /// volume differences).
    static func globalMax(slots: [CostUsageStackedDaySlot]) -> Int {
        slots.flatMap(\.segments).map(Self.resolvedTotal(for:)).max() ?? 0
    }

    /// One day's grouped column → `height` screen rows. Each row concatenates every
    /// provider's glyph (colored) with the inner/day gaps, so the day reads as N thin
    /// side-by-side bars when stacked vertically. All bars use the same `maxValue`.
    static func groupedDayColumn(
        slot: CostUsageStackedDaySlot,
        providers: [UsageProvider],
        maxValue: Int,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        height: Int,
        layout: GroupedBarLayout,
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        guard height > 0 else { return [] }
        // One per-provider bar (height rows, top → bottom), all scaled to maxValue.
        let bars: [[String]] = providers.map { provider in
            let value = slot.segments.first(where: { $0.provider == provider }).map(Self.resolvedTotal(for:)) ?? 0
            return Self.singleProviderBar(
                value: value, max: maxValue, height: height, isFuture: slot.isFuture,
                provider: provider, isToday: slot.isToday, palette: palette,
                useColor: useColor, enhanced: enhanced)
        }

        let innerGap = String(repeating: " ", count: layout.innerGap)
        let dayPad = String(repeating: " ", count: layout.dayGap)
        return (0..<height).map { row in
            let barRow = bars.map { $0[row] }.joined(separator: innerGap)
            return barRow + dayPad
        }
    }

    /// A single provider's 1-column bar: `height` rows (top → bottom), each a colored
    /// block glyph sized against `max`. Empty rows are plain spaces.
    static func singleProviderBar(
        value: Int,
        max maxValue: Int,
        height: Int,
        isFuture: Bool,
        provider: UsageProvider,
        isToday: Bool,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        guard height > 0, !isFuture, maxValue > 0, value > 0 else {
            return Array(repeating: " ", count: height)
        }
        let eighths = Self.eighths(forValue: value, max: maxValue, height: height)
        let filledRows = Swift.max(1, Swift.min(height, (eighths + 7) / 8))
        return (0..<height).map { rowFromTop in
            let rowFromBottom = height - 1 - rowFromTop
            let cellStart = rowFromBottom * 8
            let fullness: Int
            if eighths >= cellStart + 8 {
                fullness = 8
            } else if eighths > cellStart {
                fullness = eighths - cellStart
            } else {
                fullness = 0
            }
            // Vertical gradient over the filled extent (dark base → light tip), matching
            // the card progress bars' gradient language.
            let gradient = filledRows <= 1 ? 1.0 : Double(rowFromBottom) / Double(filledRows - 1)
            return Self.renderStackedCell(
                provider: fullness > 0 ? provider : nil,
                fullness: fullness,
                isToday: isToday,
                palette: palette,
                useColor: useColor,
                enhanced: enhanced,
                gradient: gradient)
        }
    }

    /// Resolved total for a segment: explicit `totalTokens`, else the component sum.
    static func resolvedTotal(for segment: CostUsageStackedSegment) -> Int {
        if let total = segment.totalTokens { return total }
        return (segment.inputTokens ?? 0) + (segment.outputTokens ?? 0)
            + (segment.cacheReadTokens ?? 0) + (segment.cacheCreationTokens ?? 0)
    }

    /// Eighths (out of `height * 8`) representing `value` against `maxValue`.
    static func eighths(forValue value: Int, max maxValue: Int, height: Int) -> Int {
        guard maxValue > 0, value > 0, height > 0 else { return 0 }
        let fraction = Swift.min(1.0, Double(value) / Double(maxValue))
        return Swift.max(0, Int((fraction * Double(height) * 8).rounded()))
    }

    /// Largest-remainder distribution of `total` eighths across `segments`, proportional to
    /// each segment's value. Guarantees the parts sum exactly to `total`.
    static func distributeEighths(segments: [Int], total: Int) -> [Int] {
        guard !segments.isEmpty else { return [] }
        let sum = segments.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 0, count: segments.count) }
        let raw = segments.map { Double($0) * Double(total) / Double(sum) }
        var floor = raw.map { Int($0.rounded(.down)) }
        var remainder = total - floor.reduce(0, +)
        // Rank by fractional part desc; bump the top entries until remainder is exhausted.
        let order = (0..<raw.count).sorted { lhs, rhs in
            let leftFrac = raw[lhs] - Double(floor[lhs])
            let rightFrac = raw[rhs] - Double(floor[rhs])
            return leftFrac == rightFrac ? lhs < rhs : leftFrac > rightFrac
        }
        var index = 0
        while remainder > 0, !order.isEmpty {
            floor[order[index % order.count]] += 1
            remainder -= 1
            index += 1
        }
        return floor
    }

    /// Today-highlight accent (the card theme's purple), shared by bars, labels, and cells.
    static let todayAccentRGB = (r: 198, g: 146, b: 255)

    /// Scales a palette color toward its dark end: `gradient` 0 (base) → 1 (tip).
    /// Bottom rows sit at ~55% brightness so a tall bar reads like the card bars' gradient.
    static func gradientRGB(_ rgb: (r: Int, g: Int, b: Int), gradient: Double) -> (r: Int, g: Int, b: Int) {
        let t = Swift.max(0, Swift.min(1, gradient))
        let scale = 0.55 + 0.45 * t
        return (Int(Double(rgb.r) * scale), Int(Double(rgb.g) * scale), Int(Double(rgb.b) * scale))
    }

    /// Renders one row of a stacked column. `fullness` 0...8 picks the glyph; `provider`
    /// picks the color (nil = empty cell, plain space). `gradient` positions the row
    /// within the bar's filled extent for the vertical dark→light gradient.
    static func renderStackedCell(
        provider: UsageProvider?,
        fullness: Int,
        isToday: Bool,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        useColor: Bool,
        enhanced: Bool,
        gradient: Double = 1.0) -> String
    {
        guard fullness > 0, let provider else { return " " }
        let glyph = fullness >= 8 ? "█" : Self.partialBlocks[Swift.min(7, fullness - 1)]
        let text = String(glyph)
        guard useColor else { return text }
        // Today's column always renders in the accent purple so it stands out regardless
        // of provider; it still carries the same vertical gradient as the provider bars.
        let base = isToday ? Self.todayAccentRGB : (palette[provider] ?? Self.providerFallbackRGB)
        let rgb = Self.gradientRGB(base, gradient: gradient)
        _ = enhanced // truecolor is used regardless of enhanced cards mode
        return CLIRenderer.ansiTrueColor(red: rgb.r, green: rgb.g, blue: rgb.b, text)
    }

    /// Single glyph colorized with a provider's color (sparkline use).
    static func colorizeStackedGlyph(
        _ glyph: Character,
        provider: UsageProvider?,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let text = String(glyph)
        guard useColor, glyph != " ", let provider else { return text }
        let rgb = palette[provider] ?? Self.providerFallbackRGB
        _ = enhanced
        return CLIRenderer.ansiTrueColor(red: rgb.r, green: rgb.g, blue: rgb.b, text)
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
        // Fork: ■ (U+25A0) square glyph + 1-space gap — readable as discrete cells, and
        // the teal ramp below gives each level its own clearly distinguishable shade.
        let glyph = "■"
        if slot.isToday {
            return CLIRenderer.colorizeEnhancedAccentBold(glyph) + " "
        }
        // Level 0 is a navy one step lighter than the terminal background — the grid
        // stays visible without competing with filled cells.
        if level == 0 {
            let c = Self.emptyCellRGB
            return CLIRenderer.ansiTrueColor(red: c.r, green: c.g, blue: c.b, glyph) + " "
        }
        guard enhanced else {
            return "\u{001B}[36m\(glyph)\u{001B}[0m "
        }
        let c = Self.heatRampRGB(level: level)
        return CLIRenderer.ansiTrueColor(red: c.r, green: c.g, blue: c.b, glyph) + " "
    }

    /// Fork: teal heatmap ramp derived from the card progress-bar gradient
    /// (rgb(40,150,140) → rgb(90,220,200)), so the heatmap shares the cards' healthy-teal
    /// identity. Four steps from dark teal to the card bar's light end, biased toward the
    /// dark side so low-activity days stay visibly distinct from empty cells.
    static func heatRampRGB(level: Int) -> (r: Int, g: Int, b: Int) {
        let clamped = Swift.max(1, Swift.min(4, level))
        let stops: [(r: Int, g: Int, b: Int)] = [
            (30, 90, 84),    // 1 — dark teal
            (40, 150, 140),  // 2 — card bar gradient dark end
            (60, 188, 170),  // 3 — mid teal
            (90, 220, 200),  // 4 — card bar gradient light end
        ]
        return stops[clamped - 1]
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
        let today = Self.todayChip(useColor: useColor, enhanced: enhanced)
        return "  " + less + cells + more + "   " + today
    }

    /// Legend chip explaining the purple today highlight (swatch + label).
    private static func todayChip(useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return "■ today" }
        _ = enhanced
        return CLIRenderer.colorizeEnhancedAccentBold("■ today")
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

    /// Bold accent title (card mode's title treatment).
    private static func styledTitle(_ title: String, useColor: Bool, enhanced: Bool) -> String {
        guard useColor else { return title }
        if enhanced { return CLIRenderer.colorizeEnhancedAccentBold(title) }
        return CLIRenderer.colorizeAccentBold(title)
    }

    /// Input / output / cache-hit token breakdown plus cost (cost in the card's gold).
    private static func statsLine(
        _ totals: CostUsageTokenTotals, prefix: String = "", useColor: Bool, enhanced: Bool) -> String
    {
        var parts = [
            "in \(UsageFormatter.tokenCountString(totals.inputTokens))",
            "out \(UsageFormatter.tokenCountString(totals.outputTokens))",
            "cache-hit \(UsageFormatter.tokenCountString(totals.cacheReadTokens))",
            "cache-write \(UsageFormatter.tokenCountString(totals.cacheCreationTokens))",
        ]
        if !prefix.isEmpty { parts.insert(prefix, at: 0) }
        let cost = "$\(String(format: "%.2f", totals.costUSD))"
        return "  " + Self.subtle(parts.joined(separator: " · ") + " · ", useColor: useColor, enhanced: enhanced)
            + Self.gold(cost, useColor: useColor, enhanced: enhanced)
    }

    // MARK: - Fork: legend + per-model breakdown table

    /// Color swatch + provider name (in its bar color) + window total, plus a chip
    /// explaining the purple today column — the trend analogue of the card badges.
    static func providerLegend(
        totals: [CostUsageStackedProviderTotals],
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        guard !totals.isEmpty else { return [] }
        var entries = totals.map { totals -> String in
            let name = ProviderDescriptorRegistry.descriptor(for: totals.provider).metadata.displayName
            let tokens = UsageFormatter.tokenCountString(totals.totalTokens)
            let swatch = Self.swatch(for: totals.provider, palette: palette, useColor: useColor, enhanced: enhanced)
            let coloredName = Self.providerName(
                name, provider: totals.provider, palette: palette, useColor: useColor, enhanced: enhanced)
            return "\(swatch) \(coloredName) \(Self.subtle(tokens, useColor: useColor, enhanced: enhanced))"
        }
        entries.append(Self.todayChip(useColor: useColor, enhanced: enhanced))
        return ["  " + Self.subtle("legend:", useColor: useColor, enhanced: enhanced) + " "
            + entries.joined(separator: "  ")]
    }

    /// Provider name in its palette color (bold), so legend and breakdown match the bars.
    static func providerName(
        _ name: String,
        provider: UsageProvider,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        useColor: Bool,
        enhanced: Bool) -> String
    {
        guard useColor else { return name }
        _ = enhanced
        let rgb = palette[provider] ?? Self.providerFallbackRGB
        return "\u{001B}[1m" + CLIRenderer.ansiTrueColor(red: rgb.r, green: rgb.g, blue: rgb.b, name)
    }

    /// `n`-row table breaking down each provider's window totals into per-provider and
    /// per-model rows. Each provider is headed by its own in/out/cache/cost line; each of
    /// its models follows with totalTokens/cost. A single combined chart means a single
    /// table, never one section per provider.
    static func modelBreakdownTable(
        totals: [CostUsageStackedProviderTotals],
        palette: [UsageProvider: (r: Int, g: Int, b: Int)] = [:],
        useColor: Bool,
        enhanced: Bool) -> [String]
    {
        guard !totals.isEmpty else { return [] }
        var lines: [String] = [Self.subtle("  breakdown:", useColor: useColor, enhanced: enhanced)]
        for providerTotals in totals {
            let name = ProviderDescriptorRegistry.descriptor(for: providerTotals.provider).metadata.displayName
            lines.append("  " + Self.providerSummaryLine(
                name: name, totals: providerTotals, palette: palette,
                useColor: useColor, enhanced: enhanced))
            for model in providerTotals.models where model.totalTokens > 0 || model.costUSD > 0 {
                lines.append("    " + Self.modelLine(name: model.modelName, model: model,
                                                    useColor: useColor, enhanced: enhanced))
            }
        }
        return lines
    }

    /// Per-provider header row: name in its bar color, metrics subtle, cost in gold —
    /// mirroring the card header (colored name) + plan value (gold) treatment.
    static func providerSummaryLine(
        name: String,
        totals: CostUsageStackedProviderTotals,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)] = [:],
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let label = Self.providerName(
            name, provider: totals.provider, palette: palette, useColor: useColor, enhanced: enhanced)
        let metrics = [
            "tok \(UsageFormatter.tokenCountString(totals.totalTokens))",
            "in \(UsageFormatter.tokenCountString(totals.inputTokens))",
            "out \(UsageFormatter.tokenCountString(totals.outputTokens))",
            "hit \(UsageFormatter.tokenCountString(totals.cacheReadTokens))",
            "wr \(UsageFormatter.tokenCountString(totals.cacheCreationTokens))",
        ].joined(separator: " · ")
        let cost = "$\(String(format: "%.2f", totals.costUSD))"
        var line = label + Self.subtle(" · " + metrics + " · ", useColor: useColor, enhanced: enhanced)
            + Self.gold(cost, useColor: useColor, enhanced: enhanced)
        if totals.requestCount > 0 {
            line += Self.subtle(" · \(totals.requestCount) req", useColor: useColor, enhanced: enhanced)
        }
        return line
    }

    /// Per-model row: model name slightly brighter than the metrics so rows scan easily.
    static func modelLine(
        name: String,
        model: CostUsageModelBreakdownTotals,
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let modelName = Self.displayName(forModel: name)
        let label = useColor && enhanced
            ? CLIRenderer.colorizeEnhancedReadableMuted(modelName)
            : modelName
        let parts = [
            "\(UsageFormatter.tokenCountString(model.totalTokens)) tok",
            "$\(String(format: "%.2f", model.costUSD))",
            model.requestCount > 0 ? "\(model.requestCount) req" : "",
        ].filter { !$0.isEmpty }
        return label + Self.subtle(" · " + parts.joined(separator: " · "), useColor: useColor, enhanced: enhanced)
    }

    /// Fork: display-only model-name normalization for the watch breakdown table. Maps the
    /// upstream "unknown" placeholder (Codex turns with no recorded model) to a clearer
    /// label so users don't see a bare "unknown" row. Does not touch pricing or storage.
    static func displayName(forModel name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "unknown" || trimmed == "Unknown" {
            return "(unspecified)"
        }
        return trimmed
    }

    /// One-glyph color swatch for a provider, rendered in its palette color.
    static func swatch(
        for provider: UsageProvider,
        palette: [UsageProvider: (r: Int, g: Int, b: Int)],
        useColor: Bool,
        enhanced: Bool) -> String
    {
        let glyph = "█"
        guard useColor else { return glyph }
        let rgb = palette[provider] ?? Self.providerFallbackRGB
        _ = enhanced
        return CLIRenderer.ansiTrueColor(red: rgb.r, green: rgb.g, blue: rgb.b, glyph)
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
            if useColor, index < highlight.count, highlight[index] {
                line += enhanced
                    ? CLIRenderer.colorizeEnhancedAccentBold(centered)
                    : CLIRenderer.colorizeAccentBold(centered)
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
