import Foundation

/// Настройки жеста встряхивания.
///
/// Браслет шлёт код 116 при отчётливой тряске, когда жест взведён. Одиночная
/// и двойная тряска — два отдельных действия. Функция опциональная, можно
/// включить насовсем или на срок.
enum ShakeSettings {

    enum Action: String, CaseIterable, Identifiable {
        case none, findPhone, mark, dictaphone, fakeCall
        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: return "Ничего"
            case .findPhone: return "Найти телефон"
            case .mark: return "Метка: время, место, витальные"
            case .dictaphone: return "Диктофон (старт/стоп)"
            case .fakeCall: return "Фейковый звонок"
            }
        }

        var icon: String {
            switch self {
            case .none: return "slash.circle"
            case .findPhone: return "iphone.radiowaves.left.and.right"
            case .mark: return "mappin.and.ellipse"
            case .dictaphone: return "mic.fill"
            case .fakeCall: return "phone.fill"
            }
        }
    }

    /// Сроки, на которые можно взвести жест.
    enum Duration: String, CaseIterable, Identifiable {
        case hour, halfDay, day, twoDays, forever
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hour: return "На час"
            case .halfDay: return "На 12 часов"
            case .day: return "На сутки"
            case .twoDays: return "На двое суток"
            case .forever: return "Постоянно"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .hour: return 3600
            case .halfDay: return 12 * 3600
            case .day: return 24 * 3600
            case .twoDays: return 48 * 3600
            case .forever: return nil
            }
        }
    }

    private static let enabledKey = "shake.enabled"
    private static let singleKey = "shake.single"
    private static let doubleKey = "shake.double"
    private static let untilKey = "shake.until"

    /// Включён ли жест вообще (по умолчанию выключен).
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// До какого момента взведён. nil при включённом = постоянно.
    static var enabledUntil: Date? {
        get { UserDefaults.standard.object(forKey: untilKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: untilKey) }
    }

    /// Действует ли жест прямо сейчас — с учётом срока.
    static var active: Bool {
        guard enabled else { return false }
        if let until = enabledUntil, until < Date() { return false }
        return true
    }

    static func enable(for duration: Duration) {
        enabled = true
        enabledUntil = duration.seconds.map { Date().addingTimeInterval($0) }
    }

    static var singleAction: Action {
        get { UserDefaults.standard.string(forKey: singleKey).flatMap(Action.init) ?? .mark }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: singleKey) }
    }

    static var doubleAction: Action {
        get { UserDefaults.standard.string(forKey: doubleKey).flatMap(Action.init) ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: doubleKey) }
    }
}
