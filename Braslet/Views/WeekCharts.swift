import Charts
import SwiftUI

/// Общий вид всех недельных графиков.
///
/// Каждый показывает своё — сон слоями, шаги сплошным, замеры размахом с
/// точкой среднего, — но высота, толщина столбиков, скругления и оси у всех
/// одинаковые. Иначе карточки выглядят собранными из разных приложений.
enum ChartLook {
    static let height: CGFloat = 165

    /// Подписи дней имеют смысл только на неделе: на месяце они сливаются.
    static func showsDays(_ count: Int) -> Bool { count <= 7 }
    static let barWidth: MarkDimension = .ratio(0.42)
    static func barWidth(_ count: Int) -> MarkDimension {
        .ratio(count <= 7 ? 0.42 : 0.7)
    }
    static let corner: CGFloat = 4
    static let axisCount = 3

    /// Уникальный ключ дня — категория оси X. Раньше X был строкой дня недели,
    /// и на месяце «пн»…«вс» повторялись → Charts клеил бары разных недель в
    /// семь столбцов. Непрерывная дата слипание чинила, но BarMark на временной
    /// оси терял дискретную ширину «на день» — свечи диапазона исчезали.
    /// Уникальный ключ даёт и раздельные дни, и нормальные столбики.
    static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Домен оси — ключи всех дней по порядку (в т.ч. пустые), иначе один
    /// день с данными растянется на всю ширину.
    static func domain(_ days: [Date]) -> [String] { days.map(dayKey) }

    /// Ключ дня → короткая подпись дня недели, для оси на неделе.
    static func weekdayLabels(_ days: [Date]) -> [String: String] {
        Dictionary(days.map { (dayKey($0), Fmt.weekdayShort($0)) },
                   uniquingKeysWith: { first, _ in first })
    }
}

// MARK: - Сон

/// Неделя сна: столбик на день, внутри стадии друг на друге.
///
/// Стопка собирается вручную (yStart/yEnd), чтобы между стадиями остался
/// зазор — иначе соседние цвета сливаются в одну полосу.
struct SleepWeekChart: View {
    let week: [(day: Date, night: SleepNight?)]

    /// Зазор между стадиями в тех же единицах, что и данные, — в минутах.
    private let gap: Double = 4

    private let order: [SleepStage] = [.deep, .core, .rem, .awake]

    private var maxMinutes: Double {
        let longest = week.compactMap { $0.night?.asleepDuration }.max() ?? 0
        return Swift.max(60, longest / 60 * 1.15)
    }

    private var averageMinutes: Double? {
        let slept = week.compactMap { $0.night?.asleepDuration }.filter { $0 > 0 }
        guard !slept.isEmpty else { return nil }
        return slept.reduce(0, +) / Double(slept.count) / 60
    }

    var body: some View {
        Chart {
            ForEach(Array(week.enumerated()), id: \.offset) { _, item in
                if let night = item.night {
                    ForEach(stackedBars(for: night), id: \.stage) { bar in
                        BarMark(
                            x: .value("День", ChartLook.dayKey(item.day)),
                            yStart: .value("От", bar.from),
                            yEnd: .value("До", bar.to),
                            width: ChartLook.barWidth(week.count))
                        .foregroundStyle(by: .value("Стадия", bar.stage.title))
                        .cornerRadius(ChartLook.corner)
                    }
                }
            }

            if let average = averageMinutes {
                RuleMark(y: .value("Среднее", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Palette.grid)
            }
        }
        .chartForegroundStyleScale(domain: order.map(\.title), range: order.map(\.color))
        .chartXScale(domain: ChartLook.domain(week.map(\.day)))
        .chartYScale(domain: 0...maxMinutes)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: ChartLook.axisCount)) { value in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text("\(Int(minutes / 60)) ч").font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            if ChartLook.showsDays(week.count) {
                // X — ключ дня; подпись дня недели берём из карты ключ→день.
                let labels = ChartLook.weekdayLabels(week.map(\.day))
                AxisMarks(values: ChartLook.domain(week.map(\.day))) { value in
                    if let key = value.as(String.self) {
                        AxisValueLabel { Text(labels[key] ?? "").font(.caption2) }
                    }
                }
            } else {
                AxisMarks { _ in }
            }
        }
        .chartLegend(position: .bottom, spacing: 12)
    }

    private struct Bar {
        let stage: SleepStage
        let from: Double
        let to: Double
    }

    /// Складываем стадии снизу вверх, вычитая зазор из каждой.
    private func stackedBars(for night: SleepNight) -> [Bar] {
        var result: [Bar] = []
        var cursor: Double = 0
        for stage in order {
            let minutes = night.duration(of: stage) / 60
            guard minutes > 0 else { continue }
            let top = cursor + minutes
            // Короткий отрезок не режем — иначе он исчезнет совсем.
            result.append(Bar(stage: stage, from: cursor,
                              to: minutes > gap * 2 ? top - gap : top))
            cursor = top
        }
        return result
    }
}

// MARK: - Замеры

/// Неделя замеров: за каждый день размах от минимума до максимума
/// и точка среднего. Один ряд данных — один тон, легенда не нужна.
struct MetricWeekChart: View {
    let week: [(day: Date, stat: DayStat?)]
    let tint: Color
    /// Единица для подписей оси — чтобы «уд/мин» и «%» не путались.
    var suffix: String = ""

    private var bounds: ClosedRange<Double> {
        let stats = week.compactMap(\.stat)
        guard let low = stats.map(\.low).min(),
              let high = stats.map(\.high).max(), high > low else {
            return 0...100
        }
        // Шкалу не тянем к нулю: у сатурации весь разброс 96–99,
        // и от нуля все дни слились бы в одну черту.
        let margin = Swift.max(2, (high - low) * 0.2)
        return (low - margin)...(high + margin)
    }

    var body: some View {
        Chart {
            ForEach(Array(week.enumerated()), id: \.offset) { _, item in
                if let stat = item.stat {
                    BarMark(x: .value("День", ChartLook.dayKey(item.day)),
                            yStart: .value("Мин", stat.low),
                            yEnd: .value("Макс", stat.high),
                            width: ChartLook.barWidth(week.count))
                        .foregroundStyle(tint.opacity(0.28))
                        .cornerRadius(ChartLook.corner)

                    PointMark(x: .value("День", ChartLook.dayKey(item.day)),
                              y: .value("Среднее", stat.average))
                        .foregroundStyle(tint)
                        .symbolSize(60)
                }
            }
        }
        .chartXScale(domain: ChartLook.domain(week.map(\.day)))
        .chartYScale(domain: bounds)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: ChartLook.axisCount)) { value in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(Int(number))\(suffix)").font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            if ChartLook.showsDays(week.count) {
                // X — ключ дня; подпись дня недели берём из карты ключ→день.
                let labels = ChartLook.weekdayLabels(week.map(\.day))
                AxisMarks(values: ChartLook.domain(week.map(\.day))) { value in
                    if let key = value.as(String.self) {
                        AxisValueLabel { Text(labels[key] ?? "").font(.caption2) }
                    }
                }
            } else {
                AxisMarks { _ in }
            }
        }
    }
}

// MARK: - Шаги

/// Неделя шагов: один ряд данных — один тон, легенда не нужна.
struct StepsWeekChart: View {
    let week: [StepDay]

    private var average: Double? {
        let walked = week.map { Double($0.steps) }.filter { $0 > 0 }
        guard !walked.isEmpty else { return nil }
        return walked.reduce(0, +) / Double(walked.count)
    }

    var body: some View {
        Chart {
            ForEach(week) { day in
                BarMark(x: .value("День", ChartLook.dayKey(day.day)),
                        y: .value("Шаги", day.steps),
                        width: ChartLook.barWidth(week.count))
                    .foregroundStyle(Palette.steps)
                    .cornerRadius(ChartLook.corner)
                    .annotation(position: .top) {
                        // Подписи над столбиками только на неделе: на месяце
                        // они превращаются в кашу.
                        if day.steps > 0, ChartLook.showsDays(week.count) {
                            Text(Fmt.compact(day.steps))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
            }

            if let average {
                RuleMark(y: .value("Среднее", average))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Palette.grid)
            }
        }
        .chartXScale(domain: ChartLook.domain(week.map(\.day)))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: ChartLook.axisCount)) { value in
                AxisGridLine().foregroundStyle(Palette.grid)
                AxisValueLabel {
                    if let steps = value.as(Int.self) {
                        Text(Fmt.compact(steps)).font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            if ChartLook.showsDays(week.count) {
                // X — ключ дня; подпись дня недели берём из карты ключ→день.
                let labels = ChartLook.weekdayLabels(week.map(\.day))
                AxisMarks(values: ChartLook.domain(week.map(\.day))) { value in
                    if let key = value.as(String.self) {
                        AxisValueLabel { Text(labels[key] ?? "").font(.caption2) }
                    }
                }
            } else {
                AxisMarks { _ in }
            }
        }
    }
}
