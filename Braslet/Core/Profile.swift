import Foundation

/// Данные владельца — только для расчётов.
///
/// Нигде не выводятся на экран: пользы в показе нет. Вес и процент жира можно
/// поправить в техническом поле (три точки страницы лога) — владелец меряет их
/// биоимпедансом раз в пару недель, и оба значения плавают. Правки хранятся в
/// UserDefaults, значения по умолчанию — последний известный замер.
///
/// Часть подтверждается перехватом: в `USERINFO` браслету уходят байты `bb 64`
/// — рост 187 и вес 100 (на момент перехвата).
enum Profile {
    static let age = 22
    static let heightCm = 187
    static let isMale = true

    private static let weightKey = "profile.weightKg"
    private static let bodyFatKey = "profile.bodyFatPercent"

    /// Вес. По умолчанию 99 (замер 15 августа), правится в настройках.
    static var weightKg: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: weightKey)
            return stored > 0 ? stored : 99.0
        }
        set { UserDefaults.standard.set(newValue, forKey: weightKey) }
    }

    /// Процент жира. По умолчанию 15, правится в настройках.
    static var bodyFatPercent: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: bodyFatKey)
            return stored > 0 ? stored : 15.0
        }
        set { UserDefaults.standard.set(newValue, forKey: bodyFatKey) }
    }

    /// Максимальный пульс.
    ///
    /// Формула Танака (`208 − 0,7×возраст`) точнее старой `220 − возраст`.
    /// Но если из тренировок известен реально наблюдавшийся максимум выше —
    /// берём его: он ближе к правде, чем любая формула. Наблюдаемый максимум
    /// подставляет вызывающий (у хранилища есть история пульса).
    static var maxHeartByFormula: Double { 208 - 0.7 * Double(age) }

    static func maxHeart(observed: Double?) -> Double {
        max(maxHeartByFormula, observed ?? 0)
    }

    /// Совместимость: там, где наблюдаемый максимум недоступен, — формула.
    static var maxHeart: Double { maxHeartByFormula }

    /// Безжировая масса — по ней точнее считается расход энергии.
    static var leanMassKg: Double { weightKg * (1 - bodyFatPercent / 100) }

    /// Килокалории за минуту при таком пульсе — формула Кейтеля.
    /// Для колец «Фитнеса» точности хватает, и это ближе к правде,
    /// чем счёт по одним шагам.
    static func kcalPerMinute(heart bpm: Double) -> Double {
        guard bpm > 50 else { return 0 }
        let value = isMale
            ? -55.0969 + 0.6309 * bpm + 0.1988 * weightKg + 0.2017 * Double(age)
            : -20.4022 + 0.4472 * bpm - 0.1263 * weightKg + 0.0740 * Double(age)
        return max(0, value / 4.184)
    }

    /// VO2max по формуле Uth: `15 × ЧССmax / ЧССпокоя`.
    ///
    /// Простая валидированная оценка аэробной формы — та же, что крутят
    /// фитнес-часы. Не лаборатория, но легитимный ориентир и тренд.
    /// Возвращает nil, пока нет пульса покоя.
    static func vo2max(restingHeart: Double?, maxHeart: Double) -> Double? {
        guard let resting = restingHeart, resting > 30, maxHeart > resting else { return nil }
        return 15 * maxHeart / resting
    }
}
