import Foundation

/// Итог одного дня по шагам.
struct StepDay: Identifiable, Hashable, Codable, Sendable {
    let day: Date          // полночь этого дня
    let steps: Int
    let meters: Int
    let kcal: Int

    var id: Date { day }
    var kilometers: Double { Double(meters) / 1000 }
}

/// Одиночный замер: пульс, кислород или стресс.
struct MetricPoint: Identifiable, Hashable, Codable, Sendable {
    let time: Date
    let value: Double

    var id: Date { time }
}

extension Array where Element == MetricPoint {
    var latest: MetricPoint? { self.max { $0.time < $1.time } }

    /// Замеры за последние сутки — по ним считаем «сегодняшний» разброс.
    func lastDay(now: Date = Date()) -> [MetricPoint] {
        let from = now.addingTimeInterval(-24 * 3600)
        return filter { $0.time >= from }
    }

    func range() -> (min: Double, max: Double)? {
        guard let lo = map(\.value).min(), let hi = map(\.value).max() else { return nil }
        return (lo, hi)
    }

    var average: Double? {
        isEmpty ? nil : map(\.value).reduce(0, +) / Double(count)
    }
}

/// Итог одного дня по замерам: размах и среднее.
struct DayStat: Identifiable, Hashable {
    let day: Date
    let low: Double
    let average: Double
    let high: Double

    var id: Date { day }
}

extension Array where Element == MetricPoint {
    /// Ровно семь дней подряд, заканчивая сегодняшним.
    ///
    /// Дни без замеров возвращаются пустыми, а не пропускаются: иначе один
    /// день растягивается на всю ширину графика и врёт о плотности данных.
    /// Но и нулём такой день не заполняем — не мерили не значит ноль.
    func weekStats(now: Date = Date()) -> [(day: Date, stat: DayStat?)] {
        dayStats(days: 7, now: now)
    }
    func dayStats(days: Int, now: Date = Date()) -> [(day: Date, stat: DayStat?)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        var byDay: [Date: [Double]] = [:]
        for point in self {
            byDay[calendar.startOfDay(for: point.time), default: []].append(point.value)
        }

        return (0..<days).reversed().compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else {
                return nil
            }
            guard let values = byDay[day], let low = values.min(), let high = values.max()
            else { return (day, nil) }
            return (day, DayStat(day: day, low: low,
                                 average: values.reduce(0, +) / Double(values.count),
                                 high: high))
        }
    }
}

extension Array where Element == StepDay {
    /// Ровно семь дней подряд, заканчивая сегодняшним: недостающие дни — нули,
    /// иначе на графике получится обманчивая картинка из одних удачных дней.
    func lastWeek(now: Date = Date()) -> [StepDay] { lastDays(7, now: now) }

    func lastMonth(now: Date = Date()) -> [StepDay] { lastDays(30, now: now) }

    func lastDays(_ days: Int, now: Date = Date()) -> [StepDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let byDay = Dictionary(uniqueKeysWithValues: map { (cal.startOfDay(for: $0.day), $0) })

        return (0..<days).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return byDay[day] ?? StepDay(day: day, steps: 0, meters: 0, kcal: 0)
        }
    }
}

extension Array where Element == SleepNight {
    /// Те же семь дней, что и у шагов, — ночь относим ко дню пробуждения.
    func lastWeek(now: Date = Date()) -> [(day: Date, night: SleepNight?)] {
        lastDays(7, now: now)
    }

    func lastMonth(now: Date = Date()) -> [(day: Date, night: SleepNight?)] {
        lastDays(30, now: now)
    }

    func lastDays(_ days: Int, now: Date = Date()) -> [(day: Date, night: SleepNight?)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let byDay = Dictionary(map { ($0.dayOfWaking, $0) }, uniquingKeysWith: { a, b in
            a.asleepDuration >= b.asleepDuration ? a : b
        })

        return (0..<days).reversed().compactMap { back in
            guard let day = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (day, byDay[day])
        }
    }
}
