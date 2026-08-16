import Foundation

/// Непрерывный отрезок одной стадии сна.
struct SleepSegment: Identifiable, Hashable, Codable, Sendable {
    let start: Date
    let end: Date
    let stage: SleepStage

    var id: String { "\(start.timeIntervalSince1970)-\(stage.rawValue)" }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// Ночь целиком: отрезки плюс посчитанные по ним итоги.
struct SleepNight: Identifiable, Hashable, Codable, Sendable {
    let segments: [SleepSegment]

    var id: String { ISO8601DateFormatter().string(from: start) }
    var start: Date { segments.first?.start ?? .distantPast }
    var end: Date { segments.last?.end ?? .distantPast }

    /// Сколько времени провели в каждой стадии.
    func duration(of stage: SleepStage) -> TimeInterval {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
    }

    /// Сон без учёта бодрствования и времени в постели.
    var asleepDuration: TimeInterval {
        segments.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.duration }
    }

    /// Полное время от засыпания до подъёма.
    var totalDuration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Доля стадии от всего сна — для диаграммы.
    func share(of stage: SleepStage) -> Double {
        guard asleepDuration > 0 else { return 0 }
        return duration(of: stage) / asleepDuration
    }

    /// Ночь относим к тому дню, в который был подъём.
    var dayOfWaking: Date {
        Calendar.current.startOfDay(for: end)
    }
}

extension Array where Element == SleepSegment {
    /// Режем список отрезков на ночи: новая ночь начинается там,
    /// где между соседними отрезками разрыв больше двух часов.
    func groupedIntoNights(maxGap: TimeInterval = 2 * 3600) -> [SleepNight] {
        let sorted = self.sorted { $0.start < $1.start }
        var nights: [SleepNight] = []
        var current: [SleepSegment] = []

        for segment in sorted {
            if let last = current.last,
               segment.start.timeIntervalSince(last.end) > maxGap {
                nights.append(SleepNight(segments: current))
                current = []
            }
            current.append(segment)
        }
        if !current.isEmpty {
            nights.append(SleepNight(segments: current))
        }
        return nights.sorted { $0.start > $1.start }
    }
}
