import AppIntents
import Foundation
import WidgetKit

/// Флаг «браслет надет» в общем контейнере группы — чтобы и приложение, и
/// виджет читали и писали одно и то же. Раньше жил в `UserDefaults.standard`
/// приложения, куда виджет (отдельный процесс) заглянуть не может.
enum WornStore {
    static let key = "braslet.worn"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshot.group)
    }

    /// По умолчанию — надет.
    static var value: Bool {
        get { defaults?.object(forKey: key) as? Bool ?? true }
        set { defaults?.set(newValue, forKey: key) }
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
