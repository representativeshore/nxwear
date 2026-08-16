import SwiftUI

/// Развёрнутая плитка: на весь нижний полуэкран, со статистикой и кнопкой
/// «назад» слева вверху. Для обычных показателей — недельный график и замер,
/// для восстановления — разбор по факторам.
struct DetailCard: View {
    let metric: MetricPages.Metric
    @ObservedObject var store: BrasletStore
    @ObservedObject var collector: BraceletCollector
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if metric == .recovery {
                RecoveryDetail(store: store)
            } else {
                metricDetail
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassCard(cornerRadius: 20)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color(.tertiarySystemGroupedBackground)))
            }
            Image(systemName: metric.icon)
                .foregroundStyle(MetricStyle.tint(metric, store: store))
            Text(metric.title).font(.headline)
            Spacer()
            Text(MetricStyle.tileValue(metric, store: store))
                .font(.title2.weight(.bold))
                .monospacedDigit()
        }
    }

    // MARK: - Обычный показатель

    @ViewBuilder
    private var metricDetail: some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)

        switch metric {
        case .steps:
            StepsWeekChart(week: store.steps.lastWeek())
        case .heart:
            MetricWeekChart(week: store.heart.weekStats(), tint: Palette.heart)
        case .oxygen:
            MetricWeekChart(week: store.oxygen.weekStats(), tint: Palette.oxygen, suffix: "%")
        case .hrv:
            MetricWeekChart(week: store.hrv.weekStats(), tint: Palette.hrv)
        case .temperature:
            MetricWeekChart(week: store.temperature.weekStats(),
                            tint: Palette.temperature, suffix: " °C")
        case .recovery:
            EmptyView()
        }
    }

    private var caption: String {
        switch metric {
        case .steps:
            guard let today = store.steps.lastWeek().last else { return "сегодня" }
            return String(format: "сегодня · %.2f км · %d ккал",
                          today.kilometers, today.kcal)
                .replacingOccurrences(of: ".", with: ",")
        case .heart: return spread(store.heart, unit: "уд/мин")
        case .oxygen: return spread(store.oxygen, unit: "%")
        case .hrv: return "разброс между ударами · выше обычно лучше"
        case .temperature: return "кожа запястья · только когда браслет надет"
        case .recovery: return ""
        }
    }

    private func spread(_ points: [MetricPoint], unit: String) -> String {
        let day = points.lastDay()
        guard let bounds = day.range(), day.count > 1 else { return "за сутки данных мало" }
        return "за сутки \(Int(bounds.min))–\(Int(bounds.max)) \(unit)"
    }

}

// MARK: - Разбор восстановления

private struct RecoveryDetail: View {
    @ObservedObject var store: BrasletStore

    var body: some View {
        let score = store.recovery
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(score.factors.contains(where: \.available) ? "\(score.value)" : "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(MetricStyle.recoveryColor(score.level))
                Text(score.recommendation)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if case .building(let days) = score.confidence {
                Label("балл живой, точность растёт (\(days) дн. базы, полная на 14)",
                      systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(score.factors) { factor in
                FactorRow(factor: factor)
            }
        }
    }
}

private struct FactorRow: View {
    let factor: Recovery.Factor

    var body: some View {
        HStack(spacing: 8) {
            Text(factor.key.title)
                .font(.caption)
            Spacer()
            if let z = factor.z {
                // Стрелка направления: зелёный вверх — хорошо для восстановления,
                // красный вниз — плохо. z везде «восстановительный» (плюс = лучше).
                Image(systemName: z > 0.4 ? "arrow.up" : (z < -0.4 ? "arrow.down" : "equal"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(z > 0.4 ? Palette.oxygen : (z < -0.4 ? Palette.heart : .secondary))
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("нет данных")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// У нагрузки «выше/ниже нормы» читалось бы наоборот (z инвертирован),
    /// поэтому показываем фактические калории тренировки за день.
    private var statusText: String {
        if factor.key == .trainingLoad {
            let kcal = Int((factor.today ?? 0).rounded())
            return kcal > 0 ? "\(kcal) ккал" : "нет"
        }
        guard let z = factor.z else { return "" }
        if z > 0.4 { return "выше нормы" }
        if z < -0.4 { return "ниже нормы" }
        return "как обычно"
    }
}
