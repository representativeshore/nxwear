import Foundation

/// Формат файла braslet.json, который делает экспортёр на Mac.
struct BrasletPayload: Decodable, Sendable {

    struct Device: Decodable, Sendable {
        let name: String?
        let battery: Int?
    }

    struct SleepRow: Decodable, Sendable {
        let start: Int
        let end: Int
        let stage: String
    }

    struct StepRow: Decodable, Sendable {
        let day: String
        let steps: Int
        let meters: Int
        let kcal: Int
    }

    struct HeartRow: Decodable, Sendable { let t: Int; let bpm: Int }
    struct OxygenRow: Decodable, Sendable { let t: Int; let percent: Int }

    let generatedAt: Int
    let device: Device
    let sleep: [SleepRow]
    let steps: [StepRow]
    let heart: [HeartRow]
    let oxygen: [OxygenRow]
}

/// Разобранная выгрузка в терминах приложения.
struct BrasletSnapshot: Sendable {
    var generatedAt: Date
    var deviceName: String?
    var battery: Int?
    var sleep: [SleepSegment]
    var steps: [StepDay]
    var heart: [MetricPoint]
    var oxygen: [MetricPoint]
}

enum BrasletJSON {

    enum ParseError: LocalizedError {
        case notJSON

        var errorDescription: String? {
            "Файл не похож на выгрузку braslet.json."
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(data: Data) throws -> BrasletSnapshot {
        guard let payload = try? JSONDecoder().decode(BrasletPayload.self, from: data) else {
            throw ParseError.notJSON
        }

        let segments = payload.sleep.compactMap { row -> SleepSegment? in
            guard let stage = SleepStage(csv: row.stage), row.end > row.start else { return nil }
            return SleepSegment(start: Date(timeIntervalSince1970: TimeInterval(row.start)),
                                end: Date(timeIntervalSince1970: TimeInterval(row.end)),
                                stage: stage)
        }

        let steps = payload.steps.compactMap { row -> StepDay? in
            guard let day = dayFormatter.date(from: row.day) else { return nil }
            return StepDay(day: Calendar.current.startOfDay(for: day),
                           steps: row.steps, meters: row.meters, kcal: row.kcal)
        }

        func points<T>(_ rows: [T], time: (T) -> Int, value: (T) -> Int) -> [MetricPoint] {
            rows.map { MetricPoint(time: Date(timeIntervalSince1970: TimeInterval(time($0))),
                                   value: Double(value($0))) }
                .sorted { $0.time < $1.time }
        }

        return BrasletSnapshot(
            generatedAt: Date(timeIntervalSince1970: TimeInterval(payload.generatedAt)),
            deviceName: payload.device.name,
            battery: payload.device.battery,
            sleep: segments.sorted { $0.start < $1.start },
            steps: steps.sorted { $0.day < $1.day },
            heart: points(payload.heart, time: \.t, value: \.bpm),
            oxygen: points(payload.oxygen, time: \.t, value: \.percent))
    }

    static func parse(fileAt url: URL) throws -> BrasletSnapshot {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try parse(data: try Data(contentsOf: url))
    }
}
