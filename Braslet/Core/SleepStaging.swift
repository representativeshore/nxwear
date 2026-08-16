import Foundation

/// Своя разметка сна из потока DLOG (код 250) браслета.
///
/// Браслет НЕ размечает сон сам — код 6 у него всегда пуст. Разметку делал
/// Nx Wear на стороне приложения из того же сырья: посекундного потока
/// пульса и движения. Повторяем это здесь.
///
/// Формат DLOG (разобран по дампу): пакет — заголовок из 3 байт
/// (длина, длина, число записей), дальше записи по 8 байт. Первый байт —
/// тег:
///   `07 <пульс> <?> <движение> 00 00 00 00` — посекундный сэмпл, БЕЗ времени;
///   `03/04/05 <?> <время LE32> …` — редкая метка времени.
/// Метки времени привязывают поток: после метки часы = её время, каждый
/// следующий сэмпл `07` идёт +1 секунда. Так каждому сэмплу присваивается
/// время. Дальше усредняем по минутам и размечаем стадии.
///
/// Всё — чистые функции, проверяется тестами на маке.
enum SleepStaging {

    struct Sample {
        let time: Date
        let pulse: Int
        let movement: Int
    }

    struct Minute {
        let time: Date
        let pulse: Int         // медиана за минуту
        let movement: Int      // среднее за минуту
    }

    // MARK: - Разбор потока

    /// Клок-walk: метка времени ставит часы, каждый сэмпл `07` идёт +1 секунда.
    /// Порядок записей — как они пришли в потоке (это важно).
    static func samples(from records: [[UInt8]]) -> [Sample] {
        var out: [Sample] = []
        var clock: Date?
        for r in records where r.count >= 6 {
            switch r[0] {
            case 3, 4, 5:
                let ts = UInt32(r[2]) | UInt32(r[3]) << 8
                       | UInt32(r[4]) << 16 | UInt32(r[5]) << 24
                // Отсечка мусора (нули/битые метки) — скользящая, не фикс-дата:
                // прежняя верхняя граница 1_800_000_000 = 15 января 2027, после
                // которой clock не выставлялся бы и пульс тихо переставал писаться.
                let seconds = TimeInterval(ts)
                if seconds > 1_600_000_000,
                   seconds < Date().timeIntervalSince1970 + 86400 {
                    clock = Date(timeIntervalSince1970: seconds)
                }
            case 7:
                guard let now = clock, r.count >= 4 else { continue }
                let pulse = Int(r[1]), movement = Int(r[3])
                if (25...220).contains(pulse) {
                    out.append(Sample(time: now, pulse: pulse, movement: movement))
                }
                // Время НЕ накручиваем: сэмплы привязаны к последней метке
                // времени, а не идут по секунде. Метки (теги 3/4/5) тянутся
                // через всю ночь — по ним сэмплы и раскладываются. Накрутка
                // +1 сек схлопывала всю ночь в считанные минуты.
            default:
                continue
            }
        }
        return out
    }

    /// Свёртка в минуты: медиана пульса, среднее движение.
    static func minutes(from samples: [Sample]) -> [Minute] {
        let calendar = Calendar.current
        var byMinute: [Date: [Sample]] = [:]
        for s in samples {
            let key = calendar.date(bySetting: .second, value: 0, of: s.time)
                ?? s.time
            byMinute[key, default: []].append(s)
        }
        return byMinute.keys.sorted().map { key in
            let group = byMinute[key]!
            let pulses = group.map(\.pulse).sorted()
            let median = pulses[pulses.count / 2]
            let move = group.map(\.movement).reduce(0, +) / group.count
            return Minute(time: key, pulse: median, movement: move)
        }
    }

    // MARK: - Разметка стадий

    // Движение b3 в диапазоне 0–255; во сне около нуля, при пробуждении выше.
    private static let awakeMovement = 18.0
    /// Отрезок короче этого — шум, вливается в соседнюю фазу. Настоящие фазы
    /// длинные и стабильные.
    private static let minRunMinutes = 12

    /// Размечает минуты в стадии и собирает отрезки.
    ///
    /// Данные от браслета редкие и с дырами, поэтому сначала раскладываем их
    /// на непрерывную минутную сетку: пульс между известными точками
    /// интерполируем, движение в дырах считаем нулём (в дыре тихо). Дальше
    /// сглаживаем, размечаем и склеиваем в отрезки — без каши из мелких скачков.
    ///
    /// Стадия по сигналу, без навязанных долей: пульс в нижней трети размаха —
    /// глубокий, в верхней — REM (тело неподвижно, а сердце активно), между —
    /// лёгкий; заметное движение — пробуждение. Ведущее и хвостовое
    /// бодрствование обрезаем, чтобы ночь начиналась со сна.
    static func stage(_ minutes: [Minute]) -> [SleepSegment] {
        guard minutes.count >= 5 else { return [] }
        let sorted = minutes.sorted { $0.time < $1.time }
        let start = sorted[0].time
        let total = Int(sorted.last!.time.timeIntervalSince(start) / 60) + 1
        guard total >= 5, total < 24 * 60 else { return [] }

        // Известные точки по индексу минуты.
        var pulseAt = [Int: Double](), moveAt = [Int: Double]()
        for m in sorted {
            let i = Int(m.time.timeIntervalSince(start) / 60)
            pulseAt[i] = Double(m.pulse)
            moveAt[i] = Double(m.movement)
        }
        let knownIdx = pulseAt.keys.sorted()

        // Непрерывная сетка: пульс интерполируем, движение в дырах — 0.
        var pulse = [Double](repeating: 0, count: total)
        var move = [Double](repeating: 0, count: total)
        for i in 0..<total {
            pulse[i] = pulseAt[i] ?? Self.interpolate(i, knownIdx, pulseAt)
            move[i] = moveAt[i] ?? 0
        }
        let ps = Self.smooth(pulse, window: 7)
        let ms = Self.smooth(move, window: 3)

        let sortedP = ps.sorted()
        let rest = sortedP[sortedP.count / 10]
        let span = max(1, (sortedP.last ?? rest) - rest)

        func stageOf(_ i: Int) -> SleepStage {
            if ms[i] > awakeMovement { return .awake }
            let level = ps[i] - rest
            if level <= span / 3 { return .deep }
            if level >= span * 2 / 3 { return .rem }
            return .core
        }
        var stages = (0..<total).map(stageOf)
        stages = Self.modeFilter(stages, window: 5)
        stages = Self.collapseShortRuns(stages, minRun: minRunMinutes)

        // Обрезаем бодрствование по краям.
        var lo = 0
        while lo < stages.count && stages[lo] == .awake { lo += 1 }
        var hi = stages.count - 1
        while hi > lo && stages[hi] == .awake { hi -= 1 }
        guard lo < hi else { return [] }

        // Склеиваем подряд идущие стадии в отрезки.
        var segments: [SleepSegment] = []
        var runStart = lo
        for i in (lo + 1)...(hi + 1) {
            if i > hi || stages[i] != stages[runStart] {
                segments.append(SleepSegment(
                    start: start.addingTimeInterval(Double(runStart) * 60),
                    end: start.addingTimeInterval(Double(i) * 60),
                    stage: stages[runStart]))
                runStart = i
            }
        }
        return segments
    }

    /// Линейная интерполяция пульса между ближайшими известными минутами.
    private static func interpolate(_ i: Int, _ known: [Int],
                                    _ values: [Int: Double]) -> Double {
        guard !known.isEmpty else { return 0 }
        let before = known.last { $0 <= i }
        let after = known.first { $0 >= i }
        switch (before, after) {
        case let (b?, a?):
            guard a != b else { return values[b] ?? 0 }
            let t = Double(i - b) / Double(a - b)
            return (values[b] ?? 0) + ((values[a] ?? 0) - (values[b] ?? 0)) * t
        case let (b?, nil): return values[b] ?? 0
        case let (nil, a?): return values[a] ?? 0
        default: return 0
        }
    }

    private static func smooth(_ v: [Double], window: Int) -> [Double] {
        v.indices.map { i in
            let lo = max(0, i - window), hi = min(v.count - 1, i + window)
            return v[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    /// Сглаживание стадий модой в окне — убирает одиночные скачки.
    private static func modeFilter(_ s: [SleepStage], window: Int) -> [SleepStage] {
        s.indices.map { i in
            let lo = max(0, i - window), hi = min(s.count - 1, i + window)
            let counts = Dictionary(s[lo...hi].map { ($0, 1) }, uniquingKeysWith: +)
            return counts.max { $0.value < $1.value }!.key
        }
    }

    /// Вливает короткие прогоны (< minRun минут) в предыдущую фазу, пока
    /// таких не останется. Фазы сна длинные — короткие куски это шум разбора.
    private static func collapseShortRuns(_ input: [SleepStage],
                                          minRun: Int) -> [SleepStage] {
        var s = input
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < s.count {
                var j = i
                while j < s.count && s[j] == s[i] { j += 1 }
                // Короткие пробуждения не трогаем — они реальны и бывают
                // краткими. Вливаем только короткие куски сна.
                if j - i < minRun, s[i] != .awake, i > 0 || j < s.count {
                    let fill = i > 0 ? s[i - 1] : s[j]
                    for k in i..<j { s[k] = fill }
                    changed = true
                }
                i = j
            }
        }
        return s
    }

    /// Весь путь: записи DLOG → отрезки сна.
    static func segments(from records: [[UInt8]]) -> [SleepSegment] {
        stage(minutes(from: samples(from: records)))
    }
}
