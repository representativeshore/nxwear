import Foundation

/// Журнал происходящего с браслетом.
///
/// Пишется всегда, в том числе в фоне, и переживает перезапуск приложения —
/// иначе от него не было бы толку: самое интересное случается, когда на экран
/// никто не смотрит. Старше суток отбрасывается.
@MainActor
final class Journal: ObservableObject {

    static let shared = Journal()

    struct Line: Identifiable, Codable {
        let at: Date
        let text: String
        var id: String { "\(at.timeIntervalSince1970)-\(text)" }
    }

    @Published private(set) var lines: [Line] = []

    private let keepFor: TimeInterval = 24 * 3600
    private var lastSaved = Date.distantPast

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("journal.json")
    }

    init() {
        load()
    }

    func add(_ text: String) {
        lines.append(Line(at: Date(), text: text))
        prune()
        // Пишем на диск не чаще раза в пять секунд: строк бывает много,
        // а смысла сохранять каждую по отдельности нет.
        if Date().timeIntervalSince(lastSaved) > 5 {
            save()
        }
    }

    func clear() {
        lines = []
        save()
    }

    /// Всё одним текстом — чтобы скопировать и переслать.
    var plainText: String {
        lines.map { "\(Fmt.time($0.at))  \($0.text)" }.joined(separator: "\n")
    }

    private func prune() {
        let edge = Date().addingTimeInterval(-keepFor)
        if lines.first?.at ?? Date() < edge {
            lines.removeAll { $0.at < edge }
        }
        // Страховка от лавины: больше пяти тысяч строк никому не нужно.
        if lines.count > 5000 {
            lines.removeFirst(lines.count - 5000)
        }
    }

    private func save() {
        lastSaved = Date()
        try? JSONEncoder().encode(lines).write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Line].self, from: data)
        else { return }
        lines = decoded
        prune()
    }
}
