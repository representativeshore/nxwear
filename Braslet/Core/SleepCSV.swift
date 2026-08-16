import Foundation

/// Разбор CSV, который делает экспортёр на Mac.
///
/// Ожидаемый вид:
///     start datetime,end datetime,sleep
///     2026-08-12 04:45:00,2026-08-12 04:50:00,core
enum SleepCSV {

    enum ParseError: LocalizedError {
        case emptyFile
        case noUsableRows(checked: Int)

        var errorDescription: String? {
            switch self {
            case .emptyFile:
                return "Файл пустой."
            case .noUsableRows(let checked):
                return "Ни одной пригодной строки (проверено \(checked)). "
                     + "Нужны колонки: начало, конец, стадия."
            }
        }
    }

    /// Даты в файле записаны по местному времени, без указания зоны.
    private static func makeFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }

    static func parse(_ text: String) throws -> [SleepSegment] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        guard !lines.isEmpty else { throw ParseError.emptyFile }

        let formatter = makeFormatter()
        var segments: [SleepSegment] = []
        var checked = 0

        for line in lines {
            let fields = line
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count >= 3 else { continue }
            checked += 1

            // Заголовок и мусор отсеиваются сами: даты не разберутся.
            guard let start = formatter.date(from: fields[0]),
                  let end = formatter.date(from: fields[1]),
                  let stage = SleepStage(csv: fields[2]),
                  end > start
            else { continue }

            segments.append(SleepSegment(start: start, end: end, stage: stage))
        }

        guard !segments.isEmpty else { throw ParseError.noUsableRows(checked: checked) }
        return segments.sorted { $0.start < $1.start }
    }

    static func parse(fileAt url: URL) throws -> [SleepSegment] {
        // Файл может приехать из «Файлов» или AirDrop — нужен доступ к чужому контейнеру.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try parse(try String(contentsOf: url, encoding: .utf8))
    }
}
