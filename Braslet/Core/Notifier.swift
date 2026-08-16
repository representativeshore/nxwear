import Foundation
import UserNotifications

/// Уведомления пользователю. Пока одно: браслет разряжается.
enum Notifier {

    /// Разрешение спрашиваем при запуске, а не в момент отправки:
    /// вопрос среди ночи от фонового процесса выглядел бы странно,
    /// а неотвеченный — потерял бы первое уведомление.
    static func prepare() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func lowBattery(_ level: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Браслет разряжается"
        content.body = "Осталось \(level)% — поставь на зарядку."
        content.sound = .default
        // Один идентификатор: повторное уведомление заменяет прежнее,
        // а не выстраивается в очередь.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "braslet.lowBattery",
                                  content: content, trigger: nil))
    }
}
