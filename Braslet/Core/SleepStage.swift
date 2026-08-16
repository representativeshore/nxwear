import Foundation

/// Стадия сна. Значения совпадают с теми, что пишет экспортёр на Mac,
/// и один в один ложатся на категории Apple Health.
enum SleepStage: String, CaseIterable, Codable, Sendable {
    case deep
    case core
    case rem
    case awake
    case inBed

    /// Как стадия записана в CSV.
    init?(csv: String) {
        switch csv.trimmingCharacters(in: .whitespaces).lowercased() {
        case "deep": self = .deep
        case "core", "light", "asleep": self = .core
        case "rem": self = .rem
        case "awake": self = .awake
        case "in bed", "inbed": self = .inBed
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .deep: return "Глубокий"
        case .core: return "Лёгкий"
        case .rem: return "Быстрый"
        case .awake: return "Пробуждения"
        case .inBed: return "В постели"
        }
    }

    /// Считается ли стадия собственно сном (а не бодрствованием или временем в постели).
    var isAsleep: Bool {
        switch self {
        case .deep, .core, .rem: return true
        case .awake, .inBed: return false
        }
    }

    /// Порядок для диаграммы: сверху бодрствование, снизу глубокий сон.
    var depth: Int {
        switch self {
        case .awake: return 0
        case .rem: return 1
        case .core: return 2
        case .deep: return 3
        case .inBed: return 4
        }
    }
}
