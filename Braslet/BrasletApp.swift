import SwiftUI

@main
struct BrasletApp: App {

    init() {
        // Сбор начинается вместе с приложением и продолжается в фоне.
        // Браслет ничего не хранит: что не поймали — потеряно навсегда.
        BraceletCollector.shared.start()
        Notifier.prepare()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    // Запуск проверки датчиков с Mac, без нажатий на телефоне:
                    // xcrun devicectl … process launch … --  -probeSensors
                    // Связь появляется не сразу: после запуска приложение
                    // сперва находит браслет и подключается. Шесть секунд
                    // на это иногда не хватает, и замер молча отменялся —
                    // поэтому ждём именно связь, а не время.
                    @MainActor func waitForBracelet() async -> Bool {
                        for _ in 0..<60 {
                            if BraceletCollector.shared.isConnected { return true }
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        return false
                    }

                    if CommandLine.arguments.contains("-workouts") {
                        Journal.shared.add("workouts: запрашиваю доступ")
                        try? await HealthService.shared.requestAuthorization()
                        Journal.shared.add("workouts: доступ пройден")
                        let list = await HealthService.shared.recentWorkouts(days: 30)
                        Journal.shared.add("тренировок из Health: \(list.count)")
                        for w in list.prefix(15) {
                            let kcal = w.energyKcal.map { " \(Int($0)) ккал" } ?? ""
                            Journal.shared.add("  \(Fmt.day(w.date)) \(Fmt.time(w.date)) "
                                + "\(w.title) \(Int(w.duration / 60)) мин\(kcal)")
                        }
                    }
                    if CommandLine.arguments.contains("-resyncSleep") {
                        await HealthService.shared.resyncSleep(BrasletStore.shared.nights)
                    }
                    if CommandLine.arguments.contains("-fakeCall") {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        FakeCall.shared.ring()
                    }
                    if CommandLine.arguments.contains("-probeSensors") {
                        guard await waitForBracelet() else { return }
                        BraceletCollector.shared.probeSensors()
                    }
                    if CommandLine.arguments.contains("-measureExtras") {
                        guard await waitForBracelet() else { return }
                        let collector = BraceletCollector.shared
                        if let value = await collector.measureHRV() {
                            collector.keep(value, as: \.hrv)
                        }
                        if let value = await collector.measureTemperature() {
                            collector.keep(value, as: \.temperature)
                        }
                    }
                }
        }
    }
}
