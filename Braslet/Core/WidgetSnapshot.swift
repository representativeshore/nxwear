import Foundation

/// Короткая выжимка для виджета: только текущие значения.
///
/// Виджет живёт отдельным процессом и в контейнер приложения заглянуть не может,
/// поэтому обмен идёт через общий контейнер группы. Пишем при каждом обновлении
/// хранилища, читаем при отрисовке виджета.
struct WidgetSnapshot: Codable {
    /// Оценка восстановления 0–100. Заменила сон: сон уже висит в Apple Health
    /// и отдельным виджетом, дублировать незачем.
    var recovery: Int?
    var steps: Int?
    var heart: Int?
    var oxygen: Int?
    var hrv: Int?
    /// Температура кожи запястья в градусах.
    var temperature: Double?
    var battery: Int?
    /// Длительность сна прошлой ночи в секундах — для крупного виджета.
    /// Optional: старый widget.json без этого поля декодируется как nil.
    var sleep: TimeInterval?
    var updated: Date

    /// Данные протухли, если обновления не было больше часа. Браслет мерит раз
    /// в полчаса, час это два пропущенных цикла, дальше числа врут и виджет
    /// показывает их приглушённо. distantPast у пустого снапшота тоже протух.
    var isStale: Bool { Date().timeIntervalSince(updated) > 60 * 60 }

    static let empty = WidgetSnapshot(recovery: nil, steps: nil, heart: nil,
                                      oxygen: nil, hrv: nil, temperature: nil,
                                      battery: nil, sleep: nil, updated: .distantPast)

    static let group = "group.com.example.braslet"

    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("widget.json")
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> WidgetSnapshot {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}
