import AppIntents
import SwiftUI
import WidgetKit

/// Виджет для стопки: шесть текущих показателей, ничего лишнего.
///
/// Раскладка зависит от размера. В маленьком — два столбца на три строки:
/// шесть плиток в квадрат иначе не уложить, а столбец шириной в пол-виджета
/// нужен, чтобы пятизначные шаги не ужимались. В среднем места вдвое больше,
/// поэтому там три столбца на две строки и заметно крупнее шрифт.
///
/// Ни графиков, ни длинных подписей здесь нет: в стопке на виджет смотрят
/// мельком, и цвет плитки работает быстрее любой надписи.
struct BrasletWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrasletWidget", provider: Provider()) { entry in
            WidgetFace(snapshot: entry.snapshot)
                .containerBackground(for: .widget) {
                    WidgetBackground(lowBattery: entry.snapshot.battery.map { $0 < 20 } ?? false)
                }
        }
        .configurationDisplayName("Браслет")
        .description("Готовность, шаги, пульс, кислород, HRV и температура.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct Provider: TimelineProvider {
    private var sample: WidgetSnapshot {
        WidgetSnapshot(recovery: 87, steps: 6373, heart: 72, oxygen: 98,
                       hrv: 31, temperature: 33.3, battery: 80,
                       sleep: 7 * 3600 + 22 * 60, updated: Date())
    }

    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: WidgetSnapshot.load())
        // Браслет меряет раз в полчаса, чаще обновляться незачем.
        completion(Timeline(entries: [entry],
                            policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

/// Одна плитка: значок, цвет и значение.
struct Tile {
    let icon: String
    let tone: Color
    let value: String
}

/// Цвета те же, что в приложении. Шесть разных оттенков, чтобы плитки
/// различались боковым зрением, без чтения подписей.
enum Tone {
    static func of(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(rgb: dark) : UIColor(rgb: light) })
    }

    static let sleep = of(light: 0x4A3AA7, dark: 0x9085E9)
    static let steps = of(light: 0x2A78D6, dark: 0x3987E5)
    static let heart = of(light: 0xE34948, dark: 0xE66767)
    static let oxygen = of(light: 0x1BAF7A, dark: 0x199E70)
    static let hrv = of(light: 0xB0399C, dark: 0xC55BB2)
    static let temperature = of(light: 0xD1730B, dark: 0xE08A1E)
}

/// Фон виджета.
///
/// Ровная заливка на таком размере выглядит мёртвой, поэтому каждый угол
/// чуть подсвечен цветом той плитки, что в нём лежит. Подсветка слабая —
/// это подсказка, где что, а не украшение, и цифры она не глушит.
struct WidgetBackground: View {
    /// Заряд браслета ниже 20% — фон становится красным.
    let lowBattery: Bool

    @Environment(\.widgetFamily) private var family

    /// Красный приглушён до фонового: он должен кричать цветом, а не глушить
    /// цифры. В тёмной теме — тёмно-бордовый по той же причине.
    private static let alarm = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(rgb: 0x4A1512) : UIColor(rgb: 0xF7D2CE) })

    var body: some View {
        let corners = WidgetFace.cornerTones(columns: family == .systemMedium ? 3 : 2)
        ZStack {
            if lowBattery {
                // Угловые подсветки на красном не рисуем: они бы смешали
                // сигнал тревоги с обычной раскраской плиток.
                Self.alarm
            } else {
                Color(.secondarySystemGroupedBackground)
                // Угловые подсветки — подсказка «где какая плитка» — верны только
                // для сеточного layout (small/medium). У большого виджета своя
                // раскладка (шапка + 5 плиток + кнопка), там они бы врали.
                if family != .systemLarge {
                    corner(corners.topLeading, at: .topLeading)
                    corner(corners.topTrailing, at: .topTrailing)
                    corner(corners.bottomLeading, at: .bottomLeading)
                    corner(corners.bottomTrailing, at: .bottomTrailing)
                }
            }
        }
    }

    private func corner(_ tone: Color, at point: UnitPoint) -> some View {
        RadialGradient(colors: [tone.opacity(0.22), tone.opacity(0)],
                       center: point, startRadius: 0, endRadius: 110)
    }
}

struct WidgetFace: View {
    let snapshot: WidgetSnapshot

    @Environment(\.widgetFamily) private var family

    private var columns: Int { family == .systemMedium ? 3 : 2 }

    var body: some View {
        if family == .systemLarge {
            LargeFace(snapshot: snapshot)
        } else {
            grid
        }
    }

    private var grid: some View {
        let rows = tiles(from: snapshot).chunked(into: columns)
        let compact = family != .systemMedium

        return Grid(horizontalSpacing: compact ? 6 : 10,
             verticalSpacing: compact ? 2 : 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, tile in
                        view(for: tile, compact: compact)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func view(for tile: Tile, compact: Bool) -> some View {
        // Значок над числом, вплотную: так плитка занимает меньше ширины,
        // и пятизначное число остаётся читаемым.
        VStack(alignment: .leading, spacing: compact ? -2 : -3) {
            Image(systemName: tile.icon)
                .font(.system(size: compact ? 17 : 24, weight: .semibold))
                .foregroundStyle(tile.tone)
            Text(tile.value)
                .font(.system(size: compact ? 21 : 29, weight: .bold, design: .rounded))
                .monospacedDigit()
                // Четыре знака влезают целиком, пять слегка ужмутся —
                // это редкий случай, ради него уменьшать всё остальное незачем.
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Плитки

    /// Порядок один на все размеры: сперва ночь, потом день, потом то,
    /// что меряется раз в час.
    static func tiles(from snapshot: WidgetSnapshot) -> [Tile] {
        [
            Tile(icon: "bolt.heart.fill", tone: recoveryTone(snapshot.recovery),
                 value: snapshot.recovery.map { "\($0)" } ?? "—"),
            Tile(icon: "figure.walk", tone: Tone.steps,
                 value: snapshot.steps.map { "\($0)" } ?? "—"),
            Tile(icon: "heart.fill", tone: Tone.heart,
                 value: snapshot.heart.map { "\($0)" } ?? "—"),
            Tile(icon: "lungs.fill", tone: Tone.oxygen,
                 value: snapshot.oxygen.map { "\($0)%" } ?? "—"),
            Tile(icon: "waveform.path.ecg", tone: Tone.hrv,
                 value: snapshot.hrv.map { "\($0)" } ?? "—"),
            Tile(icon: "thermometer.medium", tone: Tone.temperature,
                 value: temperatureText(snapshot)),
        ]
    }

    private func tiles(from snapshot: WidgetSnapshot) -> [Tile] {
        Self.tiles(from: snapshot)
    }

    /// Какие плитки окажутся по углам — от этого зависит подсветка фона.
    static func cornerTones(columns: Int) -> (topLeading: Color, topTrailing: Color,
                                              bottomLeading: Color, bottomTrailing: Color) {
        let all = tiles(from: .empty)
        let rows = all.chunked(into: columns)
        guard let first = rows.first, let last = rows.last else {
            return (Tone.sleep, Tone.steps, Tone.hrv, Tone.temperature)
        }
        return (first.first?.tone ?? Tone.sleep, first.last?.tone ?? Tone.steps,
                last.first?.tone ?? Tone.hrv, last.last?.tone ?? Tone.temperature)
    }

    /// «7:22» — часы с минутами компактнее, чем «7 ч 22 мин».
    /// Цвет плитки восстановления по уровню: зелёный хорошо, янтарь средне,
    /// красный низко — как в приложении. Нейтральный, пока данных нет.
    static func recoveryTone(_ score: Int?) -> Color {
        guard let s = score else { return Tone.hrv }
        if s >= 70 { return Tone.oxygen }
        if s >= 45 { return Tone.temperature }
        return Tone.heart
    }

    /// «33,1°» — знак градуса нужен, иначе число неотличимо от пульса.
    private static func temperatureText(_ snapshot: WidgetSnapshot) -> String {
        guard let value = snapshot.temperature else { return "—" }
        return String(format: "%.1f°", value).replacingOccurrences(of: ".", with: ",")
    }
}

/// Крупный виджет 4×4: готовность с советом и зарядом сверху, пять показателей
/// в середине и кнопка «надет/снят» снизу. Здесь есть куда развернуть данные,
/// поэтому это не просто увеличенный квадрат.
struct LargeFace: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        let metrics = Array(WidgetFace.tiles(from: snapshot).dropFirst())  // без готовности
        VStack(alignment: .leading, spacing: 10) {
            header
            Spacer(minLength: 0)
            metricGrid(metrics)
            Spacer(minLength: 0)
            wornButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var tone: Color { WidgetFace.recoveryTone(snapshot.recovery) }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: -2) {
                Text("Готовность").font(.caption).foregroundStyle(.secondary)
                Text(snapshot.recovery.map { "\($0)" } ?? "—")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tone)
                Text(recommendation)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tone)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                BatteryMini(percent: snapshot.battery)
                Text("обновлено \(updatedText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func metricGrid(_ metrics: [Tile]) -> some View {
        // Шестая ячейка (после выноса готовности в шапку) — сон прошлой ночи,
        // просто общая длительность.
        let sleepTile = Tile(icon: "moon.zzz.fill", tone: Tone.sleep, value: sleepText)
        return Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                tile(metrics[0]); tile(metrics[1]); tile(metrics[2])
            }
            GridRow {
                tile(metrics[3]); tile(metrics[4]); tile(sleepTile)
            }
        }
    }

    /// «7:22» — часы и минуты сна прошлой ночи.
    private var sleepText: String {
        guard let s = snapshot.sleep, s > 0 else { return "—" }
        let m = Int(s / 60)
        return "\(m / 60):" + String(format: "%02d", m % 60)
    }

    private func tile(_ t: Tile) -> some View {
        VStack(alignment: .leading, spacing: -3) {
            Image(systemName: t.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(t.tone)
            Text(t.value)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var wornButton: some View {
        let worn = WornStore.value
        return Button(intent: ToggleWornIntent()) {
            HStack(spacing: 8) {
                Image(systemName: worn ? "applewatch" : "applewatch.slash")
                    .font(.system(size: 16, weight: .semibold))
                Text(worn ? "Браслет надет" : "Снят — эталоны на паузе")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(worn ? "снять" : "надеть")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(worn ? Tone.oxygen : Tone.temperature)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.tertiarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    /// Совет по нагрузке — те же пороги, что в приложении.
    private var recommendation: String {
        guard let s = snapshot.recovery else { return "точность растёт" }
        switch s {
        case 78...:   return "Можно гиревую"
        case 62..<78: return "Можно тяжёлую"
        case 45..<62: return "Можно среднюю"
        default:      return "Можно лёгкую"
        }
    }

    private var updatedText: String {
        guard snapshot.updated != .distantPast else { return "—" }
        return snapshot.updated.formatted(date: .omitted, time: .shortened)
    }
}

/// Компактная живая батарейка для виджета: корпус, заливка по проценту, цвет
/// по уровню. Своя, а не из приложения — виджет-таргет его файлы не видит.
struct BatteryMini: View {
    let percent: Int?

    private var frac: CGFloat { CGFloat(max(0, min(100, percent ?? 0))) / 100 }
    private var color: Color {
        switch percent ?? 100 {
        case ..<15: return Tone.heart
        case ..<40: return Tone.temperature
        default:    return Tone.oxygen
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1.5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.secondary.opacity(0.55), lineWidth: 1.4)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(color)
                            .frame(width: max(0, g.size.width * frac))
                    }
                    .padding(2.5)
                }
                .frame(width: 30, height: 15)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 2, height: 6)
            }
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

extension Array {
    /// Режет плитки на строки сетки.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

@main
struct BrasletWidgetBundle: WidgetBundle {
    var body: some Widget {
        BrasletWidget()
    }
}
