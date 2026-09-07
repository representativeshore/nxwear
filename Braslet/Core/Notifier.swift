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

    /// Браслет пропал со связи. Заряд приложение видит только пока браслет
    /// на связи, поэтому севший вне связи браслет порог low battery не поймает.
    /// Отдельный сигнал закрывает эту дыру. Планируем отложенный на полчаса,
    /// а не шлём сразу, чтобы короткий разрыв BLE его не поднял. При возврате
    /// на связь заявку снимаем в cancelConnectionLost, до срабатывания.
    static func connectionLost(after seconds: TimeInterval = 30 * 60) {
        let content = UNMutableNotificationContent()
        content.title = "Браслет пропал со связи"
        content.body = "Полчаса тишины, возможно разрядился или снят."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds,
                                                        repeats: false)
        // Один идентификатор, повторный разрыв заменяет прежнюю заявку.
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "braslet.connectionLost",
                                  content: content, trigger: trigger))
    }

    /// Снимает и запланированное, и уже показанное «пропал со связи».
    /// Зовём при возвращении браслета на связь.
    static func cancelConnectionLost() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["braslet.connectionLost"])
        center.removeDeliveredNotifications(withIdentifiers: ["braslet.connectionLost"])
    }
}
