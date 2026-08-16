import CoreLocation
import Foundation
import HealthKit

/// Тренировка, прочитанная из «Здоровья» (обычно записана Apple Watch).
struct WorkoutInfo: Identifiable {
    let id = UUID()
    let date: Date
    let activity: HKWorkoutActivityType
    let duration: TimeInterval
    let energyKcal: Double?

    var title: String {
        switch activity {
        case .running: return "Бег"
        case .walking: return "Ходьба"
        case .cycling: return "Велосипед"
        case .traditionalStrengthTraining: return "Силовая"
        case .functionalStrengthTraining: return "Функциональная"
        case .highIntensityIntervalTraining: return "ВИИТ"
        case .coreTraining: return "Кор"
        case .mixedCardio: return "Кардио"
        case .swimming: return "Плавание"
        case .yoga: return "Йога"
        default: return "Тренировка"
        }
    }
}

/// Запись сна в «Здоровье».
///
/// Пишем по одному образцу на каждый отрезок стадии — так Apple и просит.
/// Повторная запись той же ночи сначала стирает собственные прежние образцы,
/// поэтому загружать одно и то же можно сколько угодно раз без задвоения.
@MainActor
final class HealthService: ObservableObject {

    enum Failure: LocalizedError {
        case unavailable
        case denied

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "На этом устройстве нет «Здоровья»."
            case .denied:
                return "Нет разрешения на запись сна. "
                     + "Включи его: Здоровье → Профиль → Приложения → Браслет."
            }
        }
    }

    /// Один на всё приложение: писать в «Здоровье» надо и из фонового сбора,
    /// где никаких экранов нет.
    static let shared = HealthService()

    private let store = HKHealthStore()
    private let sleepType = HKCategoryType(.sleepAnalysis)
    private let heartType = HKQuantityType(.heartRate)
    private let oxygenType = HKQuantityType(.oxygenSaturation)
    private let stepsType = HKQuantityType(.stepCount)
    private let hrvType = HKQuantityType(.heartRateVariabilitySDNN)

    private let distanceType = HKQuantityType(.distanceWalkingRunning)
    private let cyclingType = HKQuantityType(.distanceCycling)
    private let energyType = HKQuantityType(.activeEnergyBurned)

    private var shareTypes: Set<HKSampleType> {
        [sleepType, heartType, oxygenType, stepsType, hrvType,
         distanceType, cyclingType, energyType,
         HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
    }

    @Published private(set) var isWorking = false

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw Failure.unavailable }
        // Читаем сон (для проверки) и тренировки (их владелец отмечает с Apple
        // Watch — это лучший источник тренировочной нагрузки для восстановления).
        try await store.requestAuthorization(
            toShare: shareTypes, read: [sleepType, HKObjectType.workoutType()])
    }

    /// Тренировки из «Здоровья» (обычно с Apple Watch) за последние `days` дней.
    func recentWorkouts(days: Int = 30) async -> [WorkoutInfo] {
        guard HKHealthStore.isHealthDataAvailable() else { return [] }

        let start = Date().addingTimeInterval(-Double(days) * 86400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(), predicate: predicate,
                limit: HKObjectQueryNoLimit, sortDescriptors: [sort]
            ) { _, samples, _ in
                let workouts = (samples as? [HKWorkout] ?? [])
                    .filter { $0.duration >= 60 }   // отсекаем нулёвые огрызки
                    .map { workout in
                        WorkoutInfo(
                            date: workout.endDate,
                            activity: workout.workoutActivityType,
                            duration: workout.duration,
                            energyKcal: workout.statistics(for: HKQuantityType(.activeEnergyBurned))?
                                .sumQuantity()?.doubleValue(for: .kilocalorie()))
                    }
                continuation.resume(returning: workouts)
            }
            store.execute(query)
        }
    }

    /// Отправляет в «Здоровье» то, что только что пришло с браслета.
    ///
    /// Вызывается сразу после получения, в том числе из фона: браслет ничего
    /// не хранит, и откладывать запись незачем.
    func write(harvest: BraceletProtocol.Harvest) async {
        guard HKHealthStore.isHealthDataAvailable(), !harvest.isEmpty else { return }
        guard (try? await requestAuthorization()) != nil else { return }

        var samples: [HKSample] = []

        if store.authorizationStatus(for: heartType) == .sharingAuthorized {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            samples += harvest.heart.map {
                HKQuantitySample(type: heartType,
                                 quantity: HKQuantity(unit: bpm, doubleValue: $0.value),
                                 start: $0.time, end: $0.time,
                                 metadata: Self.syncMeta("hr", $0))
            }
        }

        if store.authorizationStatus(for: oxygenType) == .sharingAuthorized {
            samples += harvest.oxygen.map {
                HKQuantitySample(type: oxygenType,
                                 quantity: HKQuantity(unit: .percent(), doubleValue: $0.value / 100),
                                 start: $0.time, end: $0.time,
                                 metadata: Self.syncMeta("spo2", $0))
            }
        }

        // Вариабельность пульса «Здоровье» хранит в миллисекундах —
        // ровно в том виде, в каком её отдаёт браслет.
        if store.authorizationStatus(for: hrvType) == .sharingAuthorized {
            let ms = HKUnit.secondUnit(with: .milli)
            samples += harvest.hrv.map {
                HKQuantitySample(type: hrvType,
                                 quantity: HKQuantity(unit: ms, doubleValue: $0.value),
                                 start: $0.time, end: $0.time,
                                 metadata: Self.syncMeta("hrv", $0))
            }
        }

        // Температуру в «Здоровье» не пишем: единственное поле, семантически
        // подходящее коже запястья (`appleSleepingWristTemperature`), Apple
        // закрыл для сторонних приложений — оно только для Apple Watch. Запрос
        // разрешения на него просто зависает, переключатель не появляется.
        // Температура тела (33 °C выглядело бы переохлаждением) не годится.
        // Поэтому температура остаётся в приложении.

        // Шаги приходят накопительным итогом за день, поэтому за каждый день
        // держим ровно один свой образец: старый стираем, новый пишем.
        if store.authorizationStatus(for: stepsType) == .sharingAuthorized {
            for day in harvest.steps {
                let end = min(Date(), Calendar.current.date(byAdding: .day,
                                                           value: 1, to: day.day) ?? day.day)
                guard end > day.day else { continue }
                let predicate = HKQuery.predicateForSamples(withStart: day.day, end: end)
                _ = try? await store.deleteObjects(of: stepsType, predicate: predicate)
                samples.append(HKQuantitySample(
                    type: stepsType,
                    quantity: HKQuantity(unit: .count(), doubleValue: Double(day.steps)),
                    start: day.day, end: end))

                // Активные калории за день — ими заполняется кольцо «Движение».
                if day.kcal > 0,
                   store.authorizationStatus(for: energyType) == .sharingAuthorized {
                    _ = try? await store.deleteObjects(of: energyType, predicate: predicate)
                    samples.append(HKQuantitySample(
                        type: energyType,
                        quantity: HKQuantity(unit: .kilocalorie(),
                                             doubleValue: Double(day.kcal)),
                        start: day.day, end: end))
                }
            }
        }

        guard !samples.isEmpty else { return }
        try? await store.save(samples)
    }

    /// Дедуп точечных образцов родным механизмом HealthKit: стабильный
    /// `syncIdentifier` (тип + метка времени) означает «это тот же образец» —
    /// повторная запись обновляет его на месте, а не плодит дубль. В отличие от
    /// стирания по диапазону это не трогает ни чужие источники, ни соседние
    /// свои образцы, и нет неатомарного delete-then-save.
    private static func syncMeta(_ prefix: String, _ point: MetricPoint) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: "\(prefix)-\(Int(point.time.timeIntervalSince1970 * 1000))",
         HKMetadataKeySyncVersion: 1]
    }

    var canWrite: Bool {
        HKHealthStore.isHealthDataAvailable()
            && store.authorizationStatus(for: sleepType) == .sharingAuthorized
    }

    /// Записывает ночь. Возвращает число сохранённых образцов.
    @discardableResult
    func write(_ night: SleepNight) async throws -> Int {
        try await write(nights: [night])
    }

    @discardableResult
    func write(nights: [SleepNight]) async throws -> Int {
        guard HKHealthStore.isHealthDataAvailable() else { throw Failure.unavailable }

        isWorking = true
        defer { isWorking = false }

        try await requestAuthorization()
        guard store.authorizationStatus(for: sleepType) == .sharingAuthorized else {
            throw Failure.denied
        }

        var saved = 0
        for night in nights {
            try await deleteOwnSamples(from: night.start, to: night.end)

            let samples = night.segments.compactMap { segment -> HKCategorySample? in
                guard let value = Self.healthValue(for: segment.stage) else { return nil }
                return HKCategorySample(
                    type: sleepType,
                    value: value.rawValue,
                    start: segment.start,
                    end: segment.end,
                    metadata: [HKMetadataKeyWasUserEntered: false])
            }
            guard !samples.isEmpty else { continue }
            try await store.save(samples)
            saved += samples.count
        }
        return saved
    }

    /// Полная пересинхронизация сна: стираем ВСЕ наши записи сна за 30 дней
    /// (чужие источники HealthKit не трогает — удаляет только своё) и пишем
    /// текущие ночи заново. Нужна, когда прежняя разметка была кривой и осела
    /// в «Здоровье» мусором за пределами новых границ ночей.
    func resyncSleep(_ nights: [SleepNight]) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard (try? await requestAuthorization()) != nil else { return }
        guard store.authorizationStatus(for: sleepType) == .sharingAuthorized else { return }

        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-30 * 24 * 3600), end: Date(), options: [])
        _ = try? await store.deleteObjects(of: sleepType, predicate: predicate)
        _ = try? await write(nights: nights)
    }

    /// Стираем только то, что записало это приложение, — чужие данные не трогаем.
    private func deleteOwnSamples(from start: Date, to end: Date) async throws {
        let predicate = HKQuery.predicateForSamples(
            withStart: start, end: end, options: [])
        _ = try? await store.deleteObjects(of: sleepType, predicate: predicate)
    }

    private static func healthValue(for stage: SleepStage) -> HKCategoryValueSleepAnalysis? {
        switch stage {
        case .deep: return .asleepDeep
        case .core: return .asleepCore
        case .rem: return .asleepREM
        case .awake: return .awake
        case .inBed: return .inBed
        }
    }
}
