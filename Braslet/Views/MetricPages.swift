import SwiftUI

/// Показатели сеткой 3×2, как в виджете: сразу видно все шесть, без прокрутки,
/// которая прятала опции. Тап по плитке разворачивает её на весь нижний
/// полуэкран — со статистикой и кнопкой «назад»; верх со сном остаётся.
struct MetricPages: View {
    @ObservedObject var store: BrasletStore
    @ObservedObject var collector: BraceletCollector

    @State private var expanded: Metric?
    /// Какой показатель сейчас меряется — чтобы на его плитке была надпись
    /// «замер», а на остальных осталась «измерить» (обе инактивны).
    @State private var measuring: Metric?
    @Namespace private var ns

    enum Metric: String, CaseIterable, Identifiable {
        case steps, heart, oxygen, hrv, temperature, recovery
        var id: String { rawValue }

        var title: String {
            switch self {
            case .steps: return "Шаги"
            case .heart: return "Пульс"
            case .oxygen: return "Кислород"
            case .hrv: return "HRV"
            case .temperature: return "Температура"
            case .recovery: return "Готовность"
            }
        }

        var icon: String {
            switch self {
            case .steps: return "figure.walk"
            case .heart: return "heart.fill"
            case .oxygen: return "lungs.fill"
            case .hrv: return "waveform.path.ecg"
            case .temperature: return "thermometer.medium"
            case .recovery: return "bolt.heart.fill"
            }
        }

        /// Можно ли замерить по кнопке (датчик включается по требованию).
        var measurable: Bool {
            switch self {
            case .heart, .oxygen, .hrv, .temperature: return true
            default: return false
            }
        }
    }

    private let columns = 3

    var body: some View {
        ZStack {
            grid
            if let metric = expanded {
                DetailCard(metric: metric, store: store, collector: collector,
                           onBack: { withAnimation(spring) { expanded = nil } })
                    .transition(.scale(scale: 0.85, anchor: anchor(of: metric))
                        .combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(spring, value: expanded)
    }

    private var spring: Animation { .spring(response: 0.34, dampingFraction: 0.86) }

    // MARK: - Сетка

    private var grid: some View {
        let rows = stride(from: 0, to: Metric.allCases.count, by: columns).map {
            Array(Metric.allCases[$0..<min($0 + columns, Metric.allCases.count)])
        }
        return GlassGroup(spacing: 6) {
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { metric in
                            Tile(metric: metric, store: store, collector: collector,
                                 measuring: $measuring)
                                .contentShape(.rect)
                                .onTapGesture { withAnimation(spring) { expanded = metric } }
                        }
                    }
                }
            }
        }
    }

    /// Плитка растёт из своего угла сетки — так разворот выглядит как
    /// увеличение именно этой плитки, а не появление из центра.
    private func anchor(of metric: Metric) -> UnitPoint {
        guard let i = Metric.allCases.firstIndex(of: metric) else { return .center }
        let col = i % columns, row = i / columns
        let x: CGFloat = [0.15, 0.5, 0.85][min(col, 2)]
        let y: CGFloat = row == 0 ? 0.2 : 0.8
        return UnitPoint(x: x, y: y)
    }
}

// MARK: - Плитка

private struct Tile: View {
    let metric: MetricPages.Metric
    @ObservedObject var store: BrasletStore
    @ObservedObject var collector: BraceletCollector
    @Binding var measuring: MetricPages.Metric?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: metric.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                Text(metric.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            ForEach(stats, id: \.self) { line in
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 2)
            if metric.measurable {
                measureButton
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(9)
        .glassCard(cornerRadius: 16)
    }

    /// Компактный замер прямо с плитки — без разворота. Датчик включается по
    /// требованию, поэтому кнопка есть только у измеряемых показателей.
    private var measureButton: some View {
        Button {
            Task { await measureNow() }
        } label: {
            // На измеряемой плитке — «замер» (без троеточия), на остальных
            // «измерить»; обе инактивны, пока идёт замер.
            Text(measuring == metric ? "замер" : "измерить")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Capsule().fill(tint.opacity(0.16)))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .disabled(collector.busy != nil || !collector.isConnected)
    }

    private func measureNow() async {
        measuring = metric
        defer { measuring = nil }
        switch metric {
        case .heart:
            // Через keep (а не store.absorbHarvest напрямую) — тогда замер, как
            // и HRV/температура, уходит и в «Здоровье», а не оседает только у нас.
            if let v = await collector.measureHeart().map(Double.init) {
                collector.keep(v, as: \.heart)
            }
        case .oxygen:
            if let v = await collector.measureOxygen().map(Double.init) {
                collector.keep(v, as: \.oxygen)
            }
        case .hrv:
            if let v = await collector.measureHRV() { collector.keep(v, as: \.hrv) }
        case .temperature:
            if let v = await collector.measureTemperature() { collector.keep(v, as: \.temperature) }
        default:
            break
        }
    }

    private var tint: Color { MetricStyle.tint(metric, store: store) }
    private var value: String { MetricStyle.tileValue(metric, store: store) }
    private var stats: [String] { MetricStyle.stats(metric, store: store) }
}

// MARK: - Общий стиль и значения

@MainActor
enum MetricStyle {
    static func tint(_ metric: MetricPages.Metric, store: BrasletStore) -> Color {
        switch metric {
        case .steps: return Palette.steps
        case .heart: return Palette.heart
        case .oxygen: return Palette.oxygen
        case .hrv: return Palette.hrv
        case .temperature: return Palette.temperature
        case .recovery: return recoveryColor(store.recovery.level)
        }
    }

    static func recoveryColor(_ level: Recovery.Score.Level) -> Color {
        switch level {
        case .high: return Palette.oxygen
        case .moderate: return Palette.temperature
        case .low: return Palette.heart
        }
    }

    static func recoveryLevelText(_ level: Recovery.Score.Level) -> String {
        switch level {
        case .high: return "хорошее"
        case .moderate: return "среднее"
        case .low: return "низкое"
        }
    }

    /// Пара коротких строк под значением — заполняют пустоту плитки полезным:
    /// размах и медиана за сутки, у шагов — дистанция и калории, у
    /// восстановления — уровень и совет.
    static func stats(_ metric: MetricPages.Metric, store: BrasletStore) -> [String] {
        switch metric {
        case .steps:
            guard let day = store.steps.lastWeek().last else { return [] }
            return [comma(String(format: "%.2f км", day.kilometers)), "\(day.kcal) ккал"]
        case .heart:
            return compact([spread(store.heart), medianLine(store.heart, "медиана %d")])
        case .oxygen:
            return compact([spread(store.oxygen, suffix: "%"),
                            medianLine(store.oxygen, "медиана %d%%")])
        case .hrv:
            return compact([spread(store.hrv), medianLine(store.hrv, "медиана %d мс")])
        case .temperature:
            let day = store.temperature.lastDay()
            guard let r = day.range(), day.count > 1 else { return [] }
            return [comma(String(format: "сутки %.1f–%.1f°", r.min, r.max))]
        case .recovery:
            var lines: [String] = []
            if case .building(let days) = store.recovery.confidence {
                // Игровой замок вместо «точность растёт»: видно, сколько осталось.
                lines.append("🔒 точность: ещё \(max(0, 14 - days)) дн.")
            } else {
                lines.append(recoveryLevelText(store.recovery.level))
            }
            lines.append(store.recovery.recommendation)
            return lines
        }
    }

    /// «сутки L–H» за последние сутки, если замеров больше одного.
    private static func spread(_ points: [MetricPoint], suffix: String = "") -> String? {
        let day = points.lastDay()
        guard let r = day.range(), day.count > 1 else { return nil }
        return "сутки \(Int(r.min))–\(Int(r.max))\(suffix)"
    }

    private static func medianLine(_ points: [MetricPoint], _ format: String) -> String? {
        let vals = points.lastDay().map(\.value).sorted()
        guard vals.count > 1 else { return nil }
        let n = vals.count
        let median = n % 2 == 1 ? vals[n / 2] : (vals[n / 2 - 1] + vals[n / 2]) / 2
        return String(format: format, Int(median.rounded()))
    }

    private static func compact(_ lines: [String?]) -> [String] { lines.compactMap { $0 } }

    private static func comma(_ s: String) -> String {
        s.replacingOccurrences(of: ".", with: ",")
    }

    static func tileValue(_ metric: MetricPages.Metric, store: BrasletStore) -> String {
        switch metric {
        case .steps: return store.steps.lastWeek().last.map { "\($0.steps)" } ?? "—"
        case .heart: return store.heart.latest.map { "\(Int($0.value))" } ?? "—"
        case .oxygen: return store.oxygen.latest.map { "\(Int($0.value))%" } ?? "—"
        case .hrv: return store.hrv.latest.map { "\(Int($0.value))" } ?? "—"
        case .temperature:
            return store.temperature.latest
                .map { String(format: "%.1f°", $0.value)
                        .replacingOccurrences(of: ".", with: ",") } ?? "—"
        case .recovery:
            let score = store.recovery
            return score.factors.contains(where: \.available) ? "\(score.value)" : "—"
        }
    }
}
