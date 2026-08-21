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
                // Факторы + три модели на одной странице: при нехватке высоты
                // карточка тихо прокручивается, вместо того чтобы резать низ.
                ScrollView(showsIndicators: false) {
                    RecoveryDetail(store: store)
                }
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

            ForEach(score.factors) { factor in
                FactorRow(factor: factor)
            }

            // Модели — компактно, той же строкой-стилистикой, что и факторы.
            ModelsBlock(store: store)

            // Что ещё не набрало историю — не прячем, а показываем замком с
            // обратным отсчётом: видно, что впереди и сколько осталось.
            LockedBlock(locked: store.locked)
        }
    }
}

// MARK: - Заблокированные характеристики

/// «Характеристика заблокирована, до разблокировки N дней» — как в игре.
/// Замок, отсчёт и полоска прогресса. Ближайшая к разблокировке — первой.
private struct LockedBlock: View {
    let locked: [BrasletStore.Locked]

    var body: some View {
        if !locked.isEmpty {
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text("Заблокировано")
                        .font(.caption)
                }
                ForEach(locked) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(countdown(item))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Palette.grid).frame(height: 3)
                                Capsule().fill(Palette.hrv.opacity(0.6))
                                    .frame(width: max(3, geo.size.width * item.progress), height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }

    private func countdown(_ item: BrasletStore.Locked) -> String {
        let d = item.daysLeft
        if d == 0 { return "вот-вот" }
        let word: String
        switch d % 10 {
        case 1 where d % 100 != 11: word = "день"
        case 2...4 where !(12...14).contains(d % 100): word = "дня"
        default: word = "дней"
        }
        return "\(item.have)/\(item.need) · ещё \(d) \(word)"
    }
}

// MARK: - Модели: ACWR, HRV-коридор, влияния

/// Три модели поверх факторов на той же странице: нагрузка острая/хроническая,
/// HRV-коридор и «что на что влияет». Каждая показывается, только когда данных
/// хватает — иначе строка не занимает место.
private struct ModelsBlock: View {
    @ObservedObject var store: BrasletStore

    var body: some View {
        let acwr = store.acwr
        let corridor = store.hrvCorridor
        let influences = store.influences

        if acwr?.ratio != nil || corridor != nil || !influences.isEmpty {
            Divider().padding(.vertical, 2)
        }

        if let acwr, let ratio = acwr.ratio, let zone = acwr.zone {
            HStack(spacing: 8) {
                Text("Нагрузка 7/28 дн")
                    .font(.caption)
                Spacer()
                Circle().fill(zoneColor(zone)).frame(width: 7, height: 7)
                Text(String(format: "%.2f · %@", ratio, zoneText(zone))
                        .replacingOccurrences(of: ".", with: ","))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if let c = corridor {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("HRV-коридор")
                        .font(.caption)
                    Spacer()
                    Text(corridorText(c))
                        .font(.caption2)
                        .foregroundStyle(c.suggestsDeload ? Palette.heart : .secondary)
                }
                CorridorBar(corridor: c)
            }
        }

        if !influences.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Что на что влияет")
                    .font(.caption)
                ForEach(influences.prefix(3)) { inf in
                    HStack(spacing: 6) {
                        Text(inf.text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 4)
                        Text(String(format: "r %.2f", inf.r)
                                .replacingOccurrences(of: ".", with: ","))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func zoneColor(_ z: Models.ACWR.Zone) -> Color {
        switch z {
        case .sweet: return Palette.oxygen
        case .caution: return Palette.temperature
        case .danger: return Palette.heart
        case .detraining: return Palette.steps
        }
    }

    private func zoneText(_ z: Models.ACWR.Zone) -> String {
        switch z {
        case .sweet: return "в норме"
        case .caution: return "на грани"
        case .danger: return "перебор"
        case .detraining: return "мало"
        }
    }

    private func corridorText(_ c: Models.HRVCorridor) -> String {
        if c.suggestsDeload { return "ниже \(c.daysBelow) дн. — разгрузка" }
        switch c.status {
        case .below: return "ниже коридора"
        case .above: return "выше — адаптируешься"
        case .inside: return "в коридоре"
        }
    }
}

/// Мини-полоса коридора: серая зона ±SWC, метка — текущее 7-дневное среднее.
private struct CorridorBar: View {
    let corridor: Models.HRVCorridor

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.grid).frame(height: 4)
                Capsule().fill(Palette.hrv.opacity(0.35))
                    .frame(width: max(2, x(corridor.upper, w) - x(corridor.lower, w)), height: 4)
                    .offset(x: x(corridor.lower, w))
                Circle().fill(markColor)
                    .frame(width: 9, height: 9)
                    .offset(x: x(corridor.rolling, w) - 4.5)
            }
            .frame(height: 9)
        }
        .frame(height: 9)
    }

    /// Шкала: коридор занимает середину, по краям запас в один коридор.
    private func x(_ v: Double, _ width: CGFloat) -> CGFloat {
        let span = max(corridor.upper - corridor.lower, 0.001)
        let lo = corridor.lower - span, hi = corridor.upper + span
        return CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * width
    }

    private var markColor: Color {
        switch corridor.status {
        case .below: return corridor.suggestsDeload ? Palette.heart : Palette.temperature
        case .above: return Palette.oxygen
        case .inside: return Palette.hrv
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

    /// У нагрузки «выше/ниже нормы» читалось бы наоборот (z инвертирован).
    /// Значение фактора — накопленная усталость по Banister (τ=7), в ккал-
    /// эквиваленте; показываем её, чтобы было видно, как спадает после тяжёлых дней.
    private var statusText: String {
        if factor.key == .trainingLoad {
            let fatigue = Int((factor.today ?? 0).rounded())
            return fatigue > 0 ? "усталость \(fatigue)" : "нет"
        }
        guard let z = factor.z else { return "" }
        if z > 0.4 { return "выше нормы" }
        if z < -0.4 { return "ниже нормы" }
        return "как обычно"
    }
}
