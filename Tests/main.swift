import Foundation

// Проверка ядра приложения.
//
// Образец намеренно вшит в тест, а не читается из файла выгрузки: живой файл
// перезаписывается каждой синхронизацией, и тест начинал падать не потому,
// что сломался код, а потому что под ним поменялись данные.
//
// Собирается под macOS:
//   swiftc Braslet/Core/*.swift Braslet/Bracelet/BraceletProtocol.swift Tests/main.swift

var failures = 0

func check(_ condition: Bool, _ what: String) {
    print(condition ? "  ✅ \(what)" : "  ❌ \(what)")
    if !condition { failures += 1 }
}

/// Ночь 12 августа — та самая, по которой сверялись с штатным приложением:
/// глубокий 81 мин, лёгкий 98, быстрый 23.
let sampleCSV = """
start datetime,end datetime,sleep
2026-08-12 04:45:00,2026-08-12 04:50:00,core
2026-08-12 04:50:00,2026-08-12 05:02:00,deep
2026-08-12 05:02:00,2026-08-12 05:07:00,core
2026-08-12 05:07:00,2026-08-12 05:20:00,deep
2026-08-12 05:20:00,2026-08-12 05:39:00,core
2026-08-12 05:39:00,2026-08-12 05:50:00,deep
2026-08-12 05:50:00,2026-08-12 06:05:00,core
2026-08-12 06:05:00,2026-08-12 06:22:00,deep
2026-08-12 06:22:00,2026-08-12 06:29:00,core
2026-08-12 06:29:00,2026-08-12 06:41:00,deep
2026-08-12 06:41:00,2026-08-12 06:49:00,core
2026-08-12 06:49:00,2026-08-12 07:05:00,deep
2026-08-12 07:05:00,2026-08-12 07:21:00,core
2026-08-12 07:21:00,2026-08-12 07:38:00,rem
2026-08-12 07:38:00,2026-08-12 07:44:00,core
2026-08-12 07:44:00,2026-08-12 07:50:00,rem
2026-08-12 07:50:00,2026-08-12 08:07:00,core
"""

print("Разбор выгрузки:\n")

do {
    let segments = try SleepCSV.parse(sampleCSV)
    print("Разобрано отрезков: \(segments.count)")

    let nights = segments.groupedIntoNights()
    print("Ночей: \(nights.count)\n")

    for night in nights {
        print("Ночь \(Fmt.day(night.dayOfWaking)) (\(Fmt.weekday(night.dayOfWaking)))")
        print("  \(Fmt.time(night.start))–\(Fmt.time(night.end)), "
            + "всего \(Fmt.duration(night.totalDuration)), "
            + "сон \(Fmt.duration(night.asleepDuration))")
        for stage in [SleepStage.deep, .core, .rem, .awake] {
            let d = night.duration(of: stage)
            if d > 0 {
                print("    \(stage.title): \(Fmt.duration(d)) — \(Fmt.percent(night.share(of: stage)))")
            }
        }
    }

    print("\nПроверки:")
    check(segments.count == 17, "отрезков ровно 17")
    check(nights.count == 1, "ночь одна")

    if let night = nights.first {
        // Те же контрольные суммы, что показывает штатное приложение.
        check(Int(night.duration(of: .deep) / 60) == 81, "глубокий сон 81 мин")
        check(Int(night.duration(of: .core) / 60) == 98, "лёгкий сон 98 мин")
        check(Int(night.duration(of: .rem) / 60) == 23, "быстрый сон 23 мин")
        check(Int(night.asleepDuration / 60) == 202, "сон всего 202 мин")
        check(night.segments.allSatisfy { $0.end > $0.start }, "все отрезки положительной длины")

        let ordered = zip(night.segments, night.segments.dropFirst())
            .allSatisfy { $0.end <= $1.start }
        check(ordered, "отрезки не накладываются друг на друга")
    }

    // Разбор мусора не должен ронять приложение.
    check((try? SleepCSV.parse("совсем не csv")) == nil, "мусорный файл отвергается")
    check((try? SleepCSV.parse("")) == nil, "пустой файл отвергается")

    let twoNights = """
    start datetime,end datetime,sleep
    2026-08-10 23:00:00,2026-08-11 03:00:00,core
    2026-08-12 01:00:00,2026-08-12 05:00:00,deep
    """
    let split = (try? SleepCSV.parse(twoNights))?.groupedIntoNights().count
    check(split == 2, "две далёкие ночи не слипаются в одну")

} catch {
    print("❌ Разбор упал: \(error.localizedDescription)")
    failures += 1
}

// ── Разбор сна из посылки браслета ──
// Собираем ту самую ночь 12 августа из отметок, которые видели в базе,
// и проверяем, что разбор даёт те же цифры, что показало штатное приложение.
print("\nРазбор сна из посылки браслета:")

let base = 1786499100                     // 04:45 по местному времени
let offsets = [0, 5, 17, 22, 35, 54, 65, 80, 97, 104, 116, 124, 140, 156, 173, 179, 185, 202]
let kinds: [UInt8] = [1, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 5, 3, 5, 3, 4]

var wire: [UInt8] = [UInt8(offsets.count), 0, 2]   // всего отметок, 0, число групп
var cursor = 0
for group in 0..<2 {
    let inGroup = min(15, offsets.count - cursor)
    wire.append(UInt8(inGroup))
    for slot in 0..<15 {
        if slot < inGroup {
            let seconds = UInt32(base + offsets[cursor + slot] * 60)
            wire.append(kinds[cursor + slot])
            wire.append(UInt8(seconds & 0xFF))
            wire.append(UInt8((seconds >> 8) & 0xFF))
            wire.append(UInt8((seconds >> 16) & 0xFF))
            wire.append(UInt8((seconds >> 24) & 0xFF))
        } else {
            wire += [0, 0, 0, 0, 0]
        }
    }
    cursor += inGroup
    if group == 0 { continue }
}

let marks = BraceletProtocol.parseSleep(body: Data(wire))
let parsedSegments = BraceletProtocol.segments(from: marks)
let night = parsedSegments.groupedIntoNights().first

check(marks.count == 18, "разобрано 18 отметок")
check(parsedSegments.count == 17, "получилось 17 отрезков")
if let night {
    check(Int(night.duration(of: .deep) / 60) == 81, "глубокий сон 81 мин")
    check(Int(night.duration(of: .core) / 60) == 98, "лёгкий сон 98 мин")
    check(Int(night.duration(of: .rem) / 60) == 23, "быстрый сон 23 мин")
    check(Int(night.asleepDuration / 60) == 202, "всего сна 202 мин")
} else {
    check(false, "ночь собралась")
}

// MARK: - Вариабельность и температура

// Байты настоящие, сняты с браслета 14 августа 2026.
print("\nВариабельность пульса и температура кожи:")

let hrvWire = Data([0x01, 0x00, 0x01, 0x8a, 0xcf, 0x7e, 0x6a, 0x25])
let hrvHarvest = BraceletProtocol.parse(type: 45, body: hrvWire)
check(hrvHarvest.hrv.count == 1, "вариабельность: один замер")
check(hrvHarvest.hrv.first?.value == 37, "вариабельность: 37 мс")

// Значение в двух байтах, десятые доли градуса: 0x014b = 331 = 33,1 °C.
let tempWire = Data([0x01, 0x00, 0x01, 0x96, 0xcf, 0x7e, 0x6a, 0x4b, 0x01, 0x00, 0x00])
let tempHarvest = BraceletProtocol.parse(type: 46, body: tempWire)
check(tempHarvest.temperature.count == 1, "температура: один замер")
check(tempHarvest.temperature.first.map { abs($0.value - 33.1) < 0.001 } == true,
      "температура: 33,1 °C")

// Тело человека тут ни при чём: 33 градуса для кожи запястья — норма,
// поэтому диапазон допускает и такие значения, и явно ошибочные отсекает.
let coldWire = Data([0x01, 0x00, 0x01, 0x96, 0xcf, 0x7e, 0x6a, 0x00, 0x00, 0x00, 0x00])
check(BraceletProtocol.parse(type: 46, body: coldWire).temperature.isEmpty,
      "температура: ноль градусов отброшен")


// MARK: - Восстановление и производные показатели

print("\nВосстановление и формулы:")

// VO2max по Uth: 15 × max / покой. При 193 и 55 → ~52.6.
let vo2 = Profile.vo2max(restingHeart: 55, maxHeart: 193)
check(vo2 != nil && abs(vo2! - 52.6) < 0.2, "VO2max по Uth ≈ 52.6")
check(Profile.vo2max(restingHeart: nil, maxHeart: 193) == nil,
      "VO2max нет без пульса покоя")

// Макс. пульс: наблюдаемый выше формулы побеждает.
check(abs(Profile.maxHeartByFormula - 192.6) < 0.01, "Танака 208−0.7×22 = 192.6")
check(Profile.maxHeart(observed: 205) == 205, "наблюдаемый максимум важнее формулы")
check(abs(Profile.maxHeart(observed: 180) - 192.6) < 0.01,
      "низкий наблюдаемый не опускает ниже формулы")

// Пульс покоя: 5-й перцентиль ночного окна, не минимум-выброс.
let restPoints = (0..<20).map { MetricPoint(time: Date().addingTimeInterval(Double($0) * 60),
                                            value: Double(55 + $0)) }
let rest = Recovery.restingHeart(from: restPoints, night: nil)
check(rest != nil && rest! <= 58, "пульс покоя у нижнего края")

// Направление оценки: сегодняшняя вариабельность выше нормы → счёт выше 50.
let goodHRV = [40.0, 42, 41, 43, 40, 42, 41, 40, 42, 41, 55]   // всплеск вверх сегодня
let flat = [Double](repeating: 60, count: 11)
let high = Recovery.compute(hrv: goodHRV, restingHeart: flat,
                            deepSleepMinutes: flat, temperature: flat)
check(high.value > 50, "рост вариабельности поднимает восстановление")

// Падение вариабельности → счёт ниже 50.
let badHRV = [40.0, 42, 41, 43, 40, 42, 41, 40, 42, 41, 25]
let low = Recovery.compute(hrv: badHRV, restingHeart: flat,
                           deepSleepMinutes: flat, temperature: flat)
check(low.value < 50, "падение вариабельности опускает восстановление")

// Точность: мало дней вариабельности → building; неделя базы → ok.
let short = Recovery.compute(hrv: [40.0, 42, 41, 55], restingHeart: [60.0, 60, 60, 60],
                             deepSleepMinutes: [60.0, 60, 60, 60], temperature: [])
if case .building = short.confidence { check(true, "3 дня базы → точность building") }
else { check(false, "3 дня базы → точность building") }

let long = Recovery.compute(hrv: Array(repeating: 40.0, count: 15),
                            restingHeart: [], deepSleepMinutes: [], temperature: [])
if case .ok = long.confidence { check(true, "14 дней базы → точность ok") }
else { check(false, "14 дней базы → точность ok") }


// MARK: - Своя разметка сна из DLOG

print("\nРазметка сна из DLOG:")

// Метка времени (тег 3) + посекундные сэмплы (тег 7): часы идут +1 сек.
// Время 1786580165 = известная метка из протокола.
func ts(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}
let anchor: UInt32 = 1786580165
var recs: [[UInt8]] = [[3, 0] + ts(anchor) + [0, 0]]
for p in [60, 61, 60, 62] {
    recs.append([7, UInt8(p), 0, 2, 0, 0, 0, 0])   // пульс p, движение 2
}
let smp = SleepStaging.samples(from: recs)
check(smp.count == 4, "клок-walk: 4 сэмпла")
check(smp.first?.pulse == 60, "первый пульс 60")
check(smp[1].time == smp[0].time, "сэмплы привязаны к метке времени, не по секунде")
check(smp.first?.movement == 2, "движение из b3")

// Сэмпл без предшествующей метки времени отбрасывается.
check(SleepStaging.samples(from: [[7, 60, 0, 2, 0, 0, 0, 0]]).isEmpty,
      "сэмпл без метки времени отброшен")

// Свёртка в минуты: одна минута, медиана пульса.
let mins = SleepStaging.minutes(from: smp)
check(mins.count == 1, "четыре секунды → одна минута")
check(mins.first?.pulse == 61, "медиана пульса за минуту")

print("\nМодели нагрузки, HRV-коридор, корреляции:")

// ACWR: ровная нагрузка 100/день → отношение 1.0, «сладкая зона».
let flatLoad = Array(repeating: 100.0, count: 28)
let acwrFlat = Models.acwr(load: flatLoad)
check(acwrFlat?.ratio.map { abs($0 - 1.0) < 0.001 } == true, "ACWR ровной нагрузки = 1.0")
check(acwrFlat?.zone == .sweet, "ровная нагрузка — сладкая зона")

// Резкий скачок: 21 день по 50, потом неделя по 200 → acute 200, chronic 87.5 → 2.29 — опасно.
let spike = Array(repeating: 50.0, count: 21) + Array(repeating: 200.0, count: 7)
check(Models.acwr(load: spike)?.zone == .danger, "скачок нагрузки — опасная зона")
check(Models.acwr(load: [1, 2, 3]) == nil, "ACWR требует ≥7 дней")
check(Models.acwr(load: Array(repeating: 0.0, count: 10))?.ratio == nil,
      "без хроники отношение не определено")

// Banister: после одного импульса усталость спадает быстрее формы.
let oneHit = [100.0] + Array(repeating: 0.0, count: 13)
let ban = Models.banister(load: oneHit)
check(ban.fatigue < ban.fitness, "через 2 недели усталость ниже формы (τ 7 vs 42)")
check(ban.fatigue > 0 && ban.fatigue < 20, "усталость τ=7 за 13 дней упала ниже 20%")
let fs = Models.fatigueSeries(load: oneHit)
check(fs.count == 14 && fs[0] == 100 && fs[1] < fs[0], "серия усталости: импульс и спад")

// HRV-коридор: ровный ряд 50 → в коридоре, разгрузка не нужна.
let flatHRV = Array(repeating: 50.0, count: 30)
let corrFlat = Models.hrvCorridor(hrv: flatHRV)
check(corrFlat?.status == .inside, "ровный HRV — внутри коридора")
check(corrFlat?.suggestsDeload == false, "ровный HRV — без разгрузки")
// Падение: 28 дней ~50±2, потом 3 дня 30 → 7-дн среднее ниже коридора ≥2 дня.
var drop: [Double] = []
for i in 0..<28 { drop.append(50 + (i % 2 == 0 ? 2 : -2)) }
drop += [30, 30, 30]
let corrDrop = Models.hrvCorridor(hrv: drop)
check(corrDrop?.status == .below, "обвал HRV — ниже коридора")
check(corrDrop?.suggestsDeload == true, "обвал HRV 3 дня — разгрузка")
check(Models.hrvCorridor(hrv: [50, 50, 50]) == nil, "коридор требует ≥14 дней")

// Лаговая корреляция: y = x, сдвинутый на 1 день → лучший лаг 1, r≈1.
let xSig: [Double] = (0..<20).map { Double($0 % 5) }          // 0,1,2,3,4,0,1,...
let yLag1: [Double] = [0.0] + Array(xSig.dropLast())            // y[i] = x[i-1]
// y сегодня = x вчера → x[i] связан с y[i+1] → лаг 1.
let lc = Models.lagCorrelation(x: xSig, y: yLag1)
check(lc?.lag == 1, "лаг восстановлен = 1")
check(lc.map { $0.r > 0.95 } == true, "корреляция сдвинутого сигнала ≈ 1")
check(lc?.isMeaningful == true, "связь значима")
check(Models.lagCorrelation(x: [1, 2, 3], y: [1, 2, 3]) == nil, "корреляция требует ≥14 точек")
// Шум: константа не коррелирует (sd=0 → nil у Пирсона).
check(Models.pearson([1, 1, 1, 1], [1, 2, 3, 4]) == nil, "константа — корреляции нет")

print(failures == 0 ? "\nВсе проверки пройдены." : "\nПровалено проверок: \(failures)")
exit(failures == 0 ? 0 : 1)
