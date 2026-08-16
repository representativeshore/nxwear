import SwiftUI

/// Шапка: связь с браслетом, заряд, шестерёнка настроек и когда последний раз
/// что-то приходило. Свой трекер тренировок убран (владелец пишет с Apple
/// Watch), поэтому нижней полосы больше нет — шестерёнка переехала сюда.
struct SyncHeader: View {
    @ObservedObject var collector: BraceletCollector
    let lastSync: Date?
    let battery: Int?
    var lastHeard: Date?

    @State private var showsSettings = false

    var body: some View {
        // Слева — статус и строка «последние данные», справа заряд и
        // шестерёнка. Заряд и шестерёнку выравниваем по вертикальному центру
        // всей шапки (высоту задаёт левый столбик), а крупный глиф шестерёнки
        // не больше этого столбика — поэтому шапку не раздвигает.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Label(collector.isConnected ? "на связи" : collector.state,
                      systemImage: collector.isConnected
                          ? "dot.radiowaves.left.and.right"
                          : "antenna.radiowaves.left.and.right.slash")
                    .font(.footnote)
                    .foregroundStyle(collector.isConnected ? Palette.oxygen : .secondary)

                Group {
                    if let lastHeard {
                        Text("последние данные в \(Fmt.time(lastHeard))")
                    } else if let lastSync {
                        Text("выгружено \(Fmt.day(lastSync)) в \(Fmt.time(lastSync))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let battery {
                HStack(spacing: 5) {
                    BatteryGauge(percent: battery, height: 15)
                    Text("\(battery)%")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            gear
        }
        .padding(.horizontal, 4)
        .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
            SettingsSheet(collector: collector)
                // Форсируем popover и на iPhone — иначе система свалит его
                // в нижний лист, а нам нужно раскрытие вниз от шестерёнки.
                .presentationCompactAdaptation(.popover)
        }
    }

    private var gear: some View {
        Button {
            showsSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
                // Без заниженной рамки: иначе глиф выходит за неё и презентация
                // при закрытии на миг обрезала бы шестерёнку сверху/снизу.
        }
        .buttonStyle(.plain)
    }

}

/// Живая батарейка: корпус с клеммой и заливка по проценту заряда.
/// Цвет заливки — по уровню (красный / жёлтый / зелёный), меняется плавно.
struct BatteryGauge: View {
    let percent: Int
    var height: CGFloat = 15

    private var frac: CGFloat { max(0, min(1, CGFloat(percent) / 100)) }
    private var color: Color {
        switch percent {
        case ..<15: return Palette.heart
        case ..<40: return Palette.temperature
        default: return Palette.oxygen
        }
    }

    var body: some View {
        let w = height * 2.0
        let lw = max(1, height * 0.09)
        let inset = lw + height * 0.13
        HStack(spacing: height * 0.12) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: lw)
                GeometryReader { g in
                    RoundedRectangle(cornerRadius: height * 0.16)
                        .fill(color)
                        .frame(width: max(0, g.size.width * frac))
                }
                .padding(inset)
            }
            .frame(width: w, height: height)

            // Клемма справа.
            RoundedRectangle(cornerRadius: height * 0.12)
                .fill(Color.secondary.opacity(0.55))
                .frame(width: height * 0.14, height: height * 0.42)
        }
        .animation(.easeInOut(duration: 0.3), value: percent)
    }
}
