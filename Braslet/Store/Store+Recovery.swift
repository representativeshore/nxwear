import Foundation

/// Восстановление и производные показатели поверх накопленных данных.
extension BrasletStore {

    /// Пульс покоя за последнюю ночь.
    var restingHeartToday: Double? {
        Recovery.restingHeart(from: heart, night: nights.first)
    }

    /// Наблюдавшийся максимум пульса из всей истории.
    var observedMaxHeart: Double? {
        Recovery.observedMaxHeart(from: heart)
    }

    /// VO2max по формуле Uth из пульса покоя и максимального.
    var vo2max: Double? {
        Profile.vo2max(restingHeart: restingHeartToday,
                       maxHeart: Profile.maxHeart(observed: observedMaxHeart))
    }

    /// Оценка восстановления. Считается из дневных рядов показателей покоя.
    var recovery: Recovery.Score {
        Recovery.compute(hrv: dailySeries(hrv),
                         restingHeart: restingHeartSeries(),
                         deepSleepMinutes: deepSleepSeries(),
                         temperature: dailySeries(temperature))
    }

    // MARK: - Дневные ряды

    /// По одному значению на день (медиана за день), старые дни впереди,
    /// сегодня в конце — как ждёт `Recovery.compute`.
    private func dailySeries(_ points: [MetricPoint], days: Int = 30) -> [Double] {
        let calendar = Calendar.current
        var byDay: [Date: [Double]] = [:]
        for point in points {
            byDay[calendar.startOfDay(for: point.time), default: []].append(point.value)
        }
        return byDay.keys.sorted().suffix(days).map { day in
            let values = byDay[day]!.sorted()
            return values[values.count / 2]
        }
    }

    /// Пульс покоя по ночам — по одному на ночь, старые впереди.
    private func restingHeartSeries(days: Int = 30) -> [Double] {
        nights.sorted { $0.start < $1.start }
              .suffix(days)
              .compactMap { Recovery.restingHeart(from: heart, night: $0) }
    }

    /// Глубокий сон по ночам в минутах — по одному на ночь, старые впереди.
    private func deepSleepSeries(days: Int = 30) -> [Double] {
        nights.sorted { $0.start < $1.start }
              .suffix(days)
              .map { $0.duration(of: .deep) / 60 }
    }
}
