import Foundation

/// Математические модели поверх накопленных дневных рядов. Всё — чистые
/// функции над массивами (как `Recovery`), проверяются тестами на маке.
/// Входы везде одинаковые: по одному значению на день, старые впереди,
/// сегодня в конце.
enum Models {

    // MARK: - Нагрузка: ACWR и Banister

    /// Отношение острой нагрузки к хронической (acute:chronic workload ratio):
    /// среднее за 7 дней / среднее за 28. Классика спортивной науки —
    /// 0.8–1.3 «сладкая зона», выше 1.5 риск перетрена, ниже 0.8 детренинг.
    struct ACWR {
        let acute: Double      // среднее за 7 дн
        let chronic: Double    // среднее за 28 дн
        let ratio: Double?     // nil, если хронической нагрузки нет

        enum Zone { case detraining, sweet, caution, danger }
        var zone: Zone? {
            guard let r = ratio else { return nil }
            if r < 0.8 { return .detraining }
            if r <= 1.3 { return .sweet }
            if r <= 1.5 { return .caution }
            return .danger
        }
    }

    /// Считает ACWR по дневной серии нагрузки. Нужно хотя бы 7 дней истории
    /// и ненулевая хроника, иначе отношение не определено.
    static func acwr(load: [Double]) -> ACWR? {
        guard load.count >= 7 else { return nil }
        let acute = mean(load.suffix(7))
        let chronic = mean(load.suffix(28))
        let ratio = chronic > 0.0001 ? acute / chronic : nil
        return ACWR(acute: acute, chronic: chronic, ratio: ratio)
    }

    /// Banister impulse-response: две экспоненциальные «памяти» от нагрузки.
    /// Усталость — быстрая (τ≈7 дн), форма — медленная (τ≈42 дн).
    /// Готовность по Banister = форма − усталость; здесь отдаём оба, а для
    /// восстановления берём усталость (накопленная острая нагрузка, а не
    /// только вчерашняя).
    struct Banister {
        let fitness: Double    // форма, τ=42
        let fatigue: Double    // усталость, τ=7
        var performance: Double { fitness - fatigue }
    }

    static func banister(load: [Double],
                         tauFitness: Double = 42, tauFatigue: Double = 7) -> Banister {
        var fitness = 0.0, fatigue = 0.0
        let kF = exp(-1 / tauFitness), kG = exp(-1 / tauFatigue)
        for l in load {
            fitness = fitness * kF + l
            fatigue = fatigue * kG + l
        }
        return Banister(fitness: fitness, fatigue: fatigue)
    }

    /// Дневная серия «усталости по Banister» — по одному значению на день,
    /// чтобы скармливать как фактор в `Recovery.compute` (сравнение с личным
    /// baseline сделает сам `Recovery`). Каждая точка — усталость на конец
    /// этого дня, учитывая всю нагрузку до него включительно.
    static func fatigueSeries(load: [Double], tau: Double = 7) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(load.count)
        var fatigue = 0.0
        let k = exp(-1 / tau)
        for l in load {
            fatigue = fatigue * k + l
            out.append(fatigue)
        }
        return out
    }

    // MARK: - HRV-коридор (Plews / Kiviniemi)

    /// Скользящее 7-дневное среднее HRV против личного коридора: среднее за
    /// 60 дней ± SWC (smallest worthwhile change = 0.5σ). Самая доказанная
    /// методика HRV-guided training: в коридоре — тренируй, ниже два дня
    /// подряд — разгрузка, выше — хорошо адаптируешься.
    struct HRVCorridor {
        let rolling: Double        // 7-дневное среднее
        let center: Double         // среднее за окно
        let lower: Double
        let upper: Double
        /// Сколько дней подряд 7-дневное среднее ниже коридора (0 — в норме).
        let daysBelow: Int

        enum Status { case below, inside, above }
        var status: Status {
            if rolling < lower { return .below }
            if rolling > upper { return .above }
            return .inside
        }
        /// Правило разгрузки: два дня подряд ниже коридора.
        var suggestsDeload: Bool { daysBelow >= 2 }
    }

    /// Нужно хотя бы 14 дней HRV, иначе коридор не оценить.
    static func hrvCorridor(hrv: [Double], window: Int = 60,
                            swcFactor: Double = 0.5) -> HRVCorridor? {
        guard hrv.count >= 14 else { return nil }
        let base = Array(hrv.suffix(window))
        let center = mean(base)
        let sd = standardDeviation(base, mean: center)
        let swc = swcFactor * sd
        let lower = center - swc, upper = center + swc

        // 7-дневные средние на каждый день, чтобы посчитать серию «ниже».
        var rollings: [Double] = []
        for i in 0..<hrv.count {
            let from = max(0, i - 6)
            rollings.append(mean(hrv[from...i]))
        }
        var daysBelow = 0
        for r in rollings.reversed() {
            if r < lower { daysBelow += 1 } else { break }
        }
        return HRVCorridor(rolling: rollings.last ?? center, center: center,
                           lower: lower, upper: upper, daysBelow: daysBelow)
    }

    // MARK: - Лаговые корреляции

    /// Кросс-корреляция Пирсона между двумя рядами с лагом 0…maxLag дней:
    /// насколько «x сегодня» связан с «y через lag дней». Возвращает лучший
    /// (по модулю) лаг и коэффициент. Нужно ≥14 перекрывающихся точек.
    struct LagCorrelation {
        let lag: Int
        let r: Double
        let n: Int

        /// Порог «стоит говорить»: |r| ≥ 0.3 и не меньше 14 точек.
        var isMeaningful: Bool { abs(r) >= 0.3 && n >= 14 }
    }

    static func lagCorrelation(x: [Double], y: [Double],
                               maxLag: Int = 3) -> LagCorrelation? {
        let n = min(x.count, y.count)
        guard n >= 14 else { return nil }
        // Выравниваем по концу (сегодня в конце у обоих).
        let xs = Array(x.suffix(n)), ys = Array(y.suffix(n))
        var best: LagCorrelation?
        for lag in 0...maxLag {
            let count = n - lag
            guard count >= 14 else { continue }
            // x[i] против y[i+lag]
            let a = Array(xs[0..<count])
            let b = Array(ys[lag..<(lag + count)])
            guard let r = pearson(a, b) else { continue }
            if best == nil || abs(r) > abs(best!.r) {
                best = LagCorrelation(lag: lag, r: r, n: count)
            }
        }
        return best
    }

    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, a.count > 2 else { return nil }
        let ma = mean(a), mb = mean(b)
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<a.count {
            let xa = a[i] - ma, xb = b[i] - mb
            num += xa * xb; da += xa * xa; db += xb * xb
        }
        let den = (da * db).squareRoot()
        guard den > 0.0001 else { return nil }
        return num / den
    }

    // MARK: - Внутреннее

    static func mean<C: Collection>(_ v: C) -> Double where C.Element == Double {
        guard !v.isEmpty else { return 0 }
        return v.reduce(0, +) / Double(v.count)
    }

    static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count - 1)
        return variance.squareRoot()
    }
}
