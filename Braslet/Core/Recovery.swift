import Foundation

/// Оценка восстановления: насколько сегодняшние показатели покоя отклонились
/// от личной нормы владельца. Тот же принцип, что у Garmin/Whoop/Oura —
/// не абсолют, а отклонение от собственного baseline.
///
/// Всё здесь — чистые функции над массивами, поэтому проверяется тестами
/// на маке. Данные подаёт хранилище.
enum Recovery {

    // MARK: - Пульс покоя

    /// Пульс покоя за ночь: устойчивый минимум, а не среднее за сутки.
    /// Берём 5-й перцентиль ночных значений — это низ без одиночных провалов.
    static func restingHeart(from heart: [MetricPoint], night: SleepNight?) -> Double? {
        let window: [Double]
        if let night {
            window = heart.filter { $0.time >= night.start && $0.time <= night.end }
                          .map(\.value)
        } else {
            // Без разметки сна — последние 8 часов как грубое ночное окно.
            let since = Date().addingTimeInterval(-8 * 3600)
            window = heart.filter { $0.time >= since }.map(\.value)
        }
        return percentile(window, 0.05, minCount: 5)
    }

    /// Наблюдавшийся максимум пульса — из всей истории.
    static func observedMaxHeart(from heart: [MetricPoint]) -> Double? {
        heart.map(\.value).max()
    }

    // MARK: - Оценка

    struct Factor: Identifiable {
        let key: Key
        let today: Double?
        let baseline: Double?
        /// Направленный z: положительный = хорошо для восстановления.
        let z: Double?

        var id: String { key.rawValue }
        var available: Bool { z != nil }

        enum Key: String {
            case hrv, restingHeart, deepSleep, temperature, trainingLoad
            var title: String {
                switch self {
                case .hrv: return "HRV"
                case .restingHeart: return "Пульс покоя"
                case .deepSleep: return "Глубокий сон"
                case .temperature: return "Температура"
                case .trainingLoad: return "Нагрузка"
                }
            }
        }
    }

    struct Score {
        let value: Int                 // 0–100
        let level: Level
        let recommendation: String
        let factors: [Factor]
        let confidence: Confidence

        enum Level { case low, moderate, high }
        enum Confidence {
            /// Baseline ещё набирается: значение неточное.
            case building(days: Int)
            case ok
        }
    }

    /// Вес входов: вариабельность — главный сигнал, дальше пульс покоя,
    /// глубокий сон, температура.
    /// Температура — самый слабый и шумный сигнал (кожа, зависит от комнаты
    /// и плотности браслета), поэтому вес маленький.
    private static let weights: [Factor.Key: Double] = [
        .hrv: 0.45, .restingHeart: 0.30, .deepSleep: 0.20, .temperature: 0.05,
        // Нагрузка — небольшой вес: тяжёлая тренировка и так бьёт по HRV/пульсу
        // покоя, поэтому напрямую только слегка темперируем, без двойного удара.
        .trainingLoad: 0.10,
    ]

    /// Считает оценку из дневных рядов показателей.
    ///
    /// Каждый ряд — по одному значению в день, новое в конце. Сегодняшнее
    /// значение сравнивается с baseline (предыдущие дни), результат —
    /// направленный z-счёт, где плюс всегда «лучше для восстановления».
    static func compute(hrv: [Double],
                        restingHeart: [Double],
                        deepSleepMinutes: [Double],
                        temperature: [Double],
                        trainingLoad: [Double] = []) -> Score {
        let factors: [Factor] = [
            factor(.hrv, hrv, higherIsBetter: true),
            factor(.restingHeart, restingHeart, higherIsBetter: false),
            factor(.deepSleep, deepSleepMinutes, higherIsBetter: true),
            factor(.temperature, temperature, higherIsBetter: false, minDays: 6),
            // Дневные калории тренировок: больше обычного = острая нагрузка =
            // хуже для восстановления. Пустая история (нет тренировок) → sd=0 →
            // фактор не считается и балл не трогает.
            factor(.trainingLoad, trainingLoad, higherIsBetter: false),
        ]

        // Взвешенный композит по доступным входам.
        var sum = 0.0, weightSum = 0.0
        for f in factors {
            guard let z = f.z, let w = weights[f.key] else { continue }
            sum += z * w
            weightSum += w
        }
        let composite = weightSum > 0 ? sum / weightSum : 0

        // Композит-z → 0–100: норма (z=0) это 50, ±1σ это ±25. Наклон 25 (а не
        // 15) раскрывает весь диапазон: композит зажат ±2, поэтому 50±25·2 =
        // [0,100]. Так исключительно хороший день реально достаёт 90–100
        // (гиревая перестаёт быть недостижимой), тяжёлый валит к нулю, а сами
        // переходы «устал/отдохнул» видны, а не тонут в ±1 балле.
        let value = Int((50 + 25 * composite).clamped(to: 0...100).rounded())

        let level: Score.Level = value >= 70 ? .high : (value >= 45 ? .moderate : .low)
        // Рекомендация по нагрузке — четыре ступени по значению, тоньше, чем
        // трёхцветный уровень: сверху вниз гиревая → тяжёлая → средняя → лёгкая.
        let recommendation: String
        switch value {
        case 78...:   recommendation = "Можно гиревую"
        case 62..<78: recommendation = "Можно тяжёлую"
        case 45..<62: recommendation = "Можно среднюю"
        default:      recommendation = "Можно лёгкую"
        }

        // Точность привязываем к глубине baseline главного входа —
        // вариабельности. Оценка не надёжнее своего основного сигнала:
        // даже полная история сна не спасёт, если вариабельности всего пара дней.
        let hrvBaselineDays = max(0, hrv.count - 1)
        let confidence: Score.Confidence =
            hrvBaselineDays >= 14 ? .ok : .building(days: hrvBaselineDays)

        return Score(value: value, level: level, recommendation: recommendation,
                     factors: factors, confidence: confidence)
    }

    // MARK: - Внутреннее

    /// Один фактор: сегодняшнее против baseline, направленный z.
    ///
    /// `minDays` — сколько дней базы нужно, чтобы фактор вообще считался.
    /// Для шумной температуры кожи порог выше: на паре дней её разброс
    /// оценивается так грубо, что любой пустяк даёт огромный z и рушит балл.
    private static func factor(_ key: Factor.Key, _ series: [Double],
                               higherIsBetter: Bool, minDays: Int = 3) -> Factor {
        guard let today = series.last, series.count >= minDays else {
            return Factor(key: key, today: series.last, baseline: nil, z: nil)
        }
        let baseline = Array(series.dropLast())
        let mean = baseline.reduce(0, +) / Double(baseline.count)
        let sd = standardDeviation(baseline, mean: mean)
        guard sd > 0.0001 else {
            return Factor(key: key, today: today, baseline: mean, z: 0)
        }
        var z = (today - mean) / sd
        if !higherIsBetter { z = -z }
        // Ограничиваем ±2σ: на короткой базе (первые дни) разброс оценивается
        // грубо, и один фактор мог бы дать дикий выброс и сорвать весь балл.
        z = z.clamped(to: -2...2)
        return Factor(key: key, today: today, baseline: mean, z: z)
    }

    private static func percentile(_ values: [Double], _ p: Double,
                                   minCount: Int) -> Double? {
        guard values.count >= minCount else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count - 1)
        return variance.squareRoot()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
