import Foundation

/// Восстановление и производные показатели поверх накопленных данных.
extension BrasletStore {

    /// Пульс покоя за последнюю ночь.
    var restingHeartToday: Double? {
        Recovery.restingHeart(from: heart, night: nights.first)
    }

    /// Наблюдавшийся максимум пульса из всей истории.
    var observedMaxHeart: Double? {
        Recovery.observedMaxHeart(from: heart)
    }

    /// VO2max по формуле Uth из пульса покоя и максимального.
    var vo2max: Double? {
        Profile.vo2max(restingHeart: restingHeartToday,
                       maxHeart: Profile.maxHeart(observed: observedMaxHeart))
    }

    /// Оценка восстановления. Считается из дневных рядов показателей покоя.
    /// Нагрузка подаётся не «вчерашними ккал», а НАКОПЛЕННОЙ усталостью по
    /// Banister (τ=7): тяжёлая неделя давит сильнее одной тяжёлой тренировки,
    /// и спад идёт плавно, а не обрывается наутро.
    var recovery: Recovery.Score {
        Recovery.compute(hrv: dailySeries(hrv),
                         restingHeart: restingHeartSeries(),
                         deepSleepMinutes: deepSleepSeries(),
                         temperature: dailySeries(temperature),
                         trainingLoad: Models.fatigueSeries(load: workoutLoad))
    }

    // MARK: - Модели для разбора

    /// Острая/хроническая нагрузка (7 дн / 28 дн).
    var acwr: Models.ACWR? { Models.acwr(load: workoutLoad) }

    /// HRV-коридор: 7-дневное среднее против личного коридора ±0.5σ.
    var hrvCorridor: Models.HRVCorridor? { Models.hrvCorridor(hrv: dailySeries(hrv, days: 60)) }

    /// Что на что влияет — лаговые корреляции по личным данным. Только
    /// значимые (|r| ≥ 0.3, ≥14 точек), отсортированы по силе.
    struct Influence: Identifiable {
        let id: String
        let text: String
        let r: Double
    }

    var influences: [Influence] {
        let hrvS = dailySeries(hrv, days: 60)
        let rhrS = restingHeartSeries(days: 60)
        let deepS = deepSleepSeries(days: 60)
        let stepsS = steps.suffix(60).map { Double($0.steps) }
        let sleepS = nights.sorted { $0.start < $1.start }.suffix(60)
                           .map { $0.asleepDuration / 60 }
        let load = workoutLoad

        // Пары (причина → следствие): ожидаемый знак, чтобы фраза была честной.
        let pairs: [(id: String, cause: String, effect: String, x: [Double], y: [Double])] = [
            ("load-hrv",   "нагрузка",      "HRV",         load,   hrvS),
            ("load-rhr",   "нагрузка",      "пульс покоя", load,   rhrS),
            ("deep-hrv",   "глубокий сон",  "HRV",         deepS,  hrvS),
            ("steps-sleep","шаги",          "сон",         stepsS, sleepS),
            ("sleep-hrv",  "сон",           "HRV",         sleepS, hrvS),
        ]

        return pairs.compactMap { p in
            guard let c = Models.lagCorrelation(x: p.x, y: p.y), c.isMeaningful else { return nil }
            let dir = c.r > 0 ? "выше" : "ниже"
            let when: String
            switch c.lag {
            case 0: when = "в тот же день"
            case 1: when = "на следующий день"
            default: when = "через \(c.lag) дня"
            }
            return Influence(id: p.id,
                             text: "\(p.cause) ↑ → \(p.effect) \(dir) \(when)",
                             r: c.r)
        }
        .sorted { abs($0.r) > abs($1.r) }
    }

    /// Тянет тренировки из «Здоровья» и складывает дневную серию калорий
    /// (по календарным дням, с нулями за дни без тренировок, сегодня в конце) —
    /// её ест фактор «Нагрузка». Зовём при входе на экран и после синка.
    func refreshWorkoutLoad(days: Int = 30) {
        Task {
            let workouts = await HealthService.shared.recentWorkouts(days: days)
            let cal = Calendar.current
            var byDay: [Date: Double] = [:]
            for w in workouts {
                byDay[cal.startOfDay(for: w.date), default: 0] += w.energyKcal ?? 0
            }
            let today = cal.startOfDay(for: Date())
            let series = (0..<days).reversed().compactMap { back -> Double? in
                cal.date(byAdding: .day, value: -back, to: today).map { byDay[$0] ?? 0 }
            }
            updateWorkoutLoad(series)
        }
    }

    // MARK: - Дневные ряды

    /// По одному значению на день (медиана за день), старые дни впереди,
    /// сегодня в конце — как ждёт `Recovery.compute`.
    private func dailySeries(_ points: [MetricPoint], days: Int = 30) -> [Double] {
        let calendar = Calendar.current
        var byDay: [Date: [Double]] = [:]
        for point in points {
            byDay[calendar.startOfDay(for: point.time), default: []].append(point.value)
        }
        return byDay.keys.sorted().suffix(days).map { day in
            let values = byDay[day]!.sorted()
            return values[values.count / 2]
        }
    }

    /// Пульс покоя по ночам — по одному на ночь, старые впереди.
    private func restingHeartSeries(days: Int = 30) -> [Double] {
        nights.sorted { $0.start < $1.start }
              .suffix(days)
              .compactMap { Recovery.restingHeart(from: heart, night: $0) }
    }

    /// Глубокий сон по ночам в минутах — по одному на ночь, старые впереди.
    private func deepSleepSeries(days: Int = 30) -> [Double] {
        nights.sorted { $0.start < $1.start }
              .suffix(days)
              .map { $0.duration(of: .deep) / 60 }
    }
}
