import AppIntents
import Foundation
import WidgetKit

/// Флаг «браслет надет» в общем контейнере группы — чтобы и приложение, и
/// виджет читали и писали одно и то же. Раньше жил в `UserDefaults.standard`
/// приложения, куда виджет (отдельный процесс) заглянуть не может.
enum WornStore {
    static let key = "braslet.worn"
    static let sinceKey = "braslet.wornSince"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshot.group)
    }

    /// По умолчанию — надет. При переходе «снят → надет» штампуем момент
    /// надевания: сразу после него браслет ещё догревается до кожи, и
    /// температуру какое-то время снимать нельзя (была бы занижена).
    static var value: Bool {
        get { defaults?.object(forKey: key) as? Bool ?? true }
        set {
            let was = value
            defaults?.set(newValue, forKey: key)
            if newValue && !was { defaults?.set(Date(), forKey: sinceKey) }
        }
    }

    /// Когда браслет надели (для окна прогрева температуры). nil — неизвестно.
    static var wornSince: Date? { defaults?.object(forKey: sinceKey) as? Date }

    /// Прогрелся ли браслет до кожи после надевания (~20 минут).
    static var temperatureSettled: Bool {
        guard value else { return false }
        guard let since = wornSince else { return true }  // давно надет
        return Date().timeIntervalSince(since) > 20 * 60
    }
}

/// Кнопка виджета «надет/снят»: переключает общий флаг и просит виджет
/// перерисоваться. Когда снят, приложение глушит авто-съём эталонов.
struct ToggleWornIntent: AppIntent {
    static var title: LocalizedStringResource = "Браслет надет или снят"

    func perform() async throws -> some IntentResult {
        WornStore.value.toggle()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
