import SwiftUI

/// Три вида сна: прошлая ночь, неделя, месяц. Переключаются не свайпом, а
/// парой кнопок внизу карточки — на каждой странице там две другие вкладки.
struct SleepPages: View {
    let nights: [SleepNight]
    @State private var page: Page = .night

    enum Page: String, CaseIterable, Identifiable, Equatable {
        case night, week, month
        var id: String { rawValue }

        var title: String {
            switch self {
            case .night: return "Прошлая ночь"
            case .week: return "Неделя"
            case .month: return "Месяц"
            }
        }

        /// Короткое имя для кнопки-переключателя.
        var short: String {
            switch self {
            case .night: return "День"
            case .week: return "Неделя"
            case .month: return "Месяц"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(SleepStage.deep.color)
                Text(page.title).font(.headline)
                Spacer()
                if page == .night, let night = nights.first {
                    Text(Fmt.duration(night.asleepDuration))
                        .font(.headline.monospacedDigit())
                }
            }

            switch page {
            case .night: lastNight
            case .week: SleepWeekChart(week: nights.lastWeek())
            case .month: SleepWeekChart(week: nights.lastMonth())
            }

            Spacer(minLength: 0)

            switcher
        }
        .cardStyle()
    }

    /// Ряд из двух кнопок — две другие вкладки. Занимает нижнюю часть карточки,
    /// которая раньше пустовала.
    private var switcher: some View {
        HStack(spacing: 8) {
            ForEach(Page.allCases.filter { $0 != page }) { target in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { page = target }
                } label: {
                    Text(target.short)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            Capsule().fill(Color(.tertiarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var lastNight: some View {
        if let night = nights.first {
            VStack(alignment: .leading, spacing: 10) {
                Text("С \(Fmt.time(night.start)) до \(Fmt.time(night.end))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HypnogramView(night: night)
                StageLegend(night: night)
            }
        } else {
            Text("Пока нет ни одной ночи. Поспи с браслетом — соберётся само.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
