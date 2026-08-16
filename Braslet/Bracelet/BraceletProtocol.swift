import Foundation

/// Протокол браслета: сборка кадров, пересборка длинных посылок, разбор пачек.
///
/// Формат восстановлен из SDK приложения — `CEProtocolB` и классы `K6_*`.
/// Здесь только чистые преобразования байтов, без Bluetooth, — поэтому
/// всё это можно проверять тестами на обычной машине.
enum BraceletProtocol {

    static let frameSize = 20
    static let headerSize = 10
    static let continuationPayload = 19

    // MARK: - Сборка

    /// Режет посылку на кадры по 20 байт.
    static func frames(command: UInt8, payload: [UInt8], sequence: UInt8) -> [Data] {
        let extraPages = payload.count <= headerSize
            ? 0
            : (payload.count - headerSize + continuationPayload - 1) / continuationPayload

        var head = [UInt8](repeating: 0, count: frameSize)
        head[0] = 0                                   // заголовочный кусок
        head[1] = 1                                   // тип устройства
        head[2] = UInt8(min(extraPages, 255))
        head[3] = sequence
        head[4] = 1                                   // вид: данные
        head[5] = command
        head[8] = UInt8(payload.count & 0xFF)
        head[9] = UInt8((payload.count >> 8) & 0xFF)
        for (i, b) in payload.prefix(headerSize).enumerated() { head[headerSize + i] = b }

        var result = [Data(head)]
        var offset = headerSize
        var index: UInt8 = 1
        while offset < payload.count {
            var page = [UInt8](repeating: 0, count: frameSize)
            page[0] = index
            let end = min(offset + continuationPayload, payload.count)
            for (i, b) in payload[offset..<end].enumerated() { page[1 + i] = b }
            result.append(Data(page))
            offset = end
            index &+= 1
        }
        return result
    }

    // MARK: - Пересборка

    /// Склеивает многокадровые посылки. Одна на соединение.
    struct Reassembler {
        private var pending: (type: UInt8, seq: UInt8, length: Int, data: Data, left: Int)?

        enum Event {
            case acknowledged(UInt8)
            /// `seq` нужен для ответного подтверждения: браслет ждёт его
            /// на каждую посылку и без него рвёт связь секунд через двадцать.
            case message(type: UInt8, seq: UInt8, body: Data)
            /// Началась длинная посылка из нескольких кусков.
            case started(type: UInt8, pages: Int, length: Int)
            /// Предыдущая посылка не дособралась — пришёл новый заголовок.
            /// Молчаливая потеря куска выглядит именно так, и это худший
            /// вид сбоя: данные исчезают, а никто об этом не узнаёт.
            case abandoned(type: UInt8, got: Int, expected: Int)
        }

        /// Возвращает СПИСОК событий: если новый заголовок пришёл поверх
        /// недособранной посылки, надо и сообщить об обрыве старой, и обработать
        /// новую. Раньше отдавалось одно событие — новое одиночное сообщение
        /// молча терялось и не подтверждалось, и браслет рвал связь.
        mutating func accept(_ frame: Data) -> [Event] {
            guard !frame.isEmpty else { return [] }

            if frame[0] != 0 {
                guard var current = pending else { return [] }
                current.data.append(frame.subdata(in: 1..<frame.count))
                current.left -= 1
                if current.left <= 0 {
                    pending = nil
                    return [.message(type: current.type, seq: current.seq,
                                     body: current.data.prefix(current.length))]
                }
                pending = current
                return []
            }

            guard frame.count >= headerSize else { return [] }
            if frame[4] & 0x0F == 4 { return [.acknowledged(frame[5])] }

            let pages = Int(frame[2])
            let length = Int(frame[8]) | (Int(frame[9]) << 8)
            let head = frame.subdata(in: headerSize..<frame.count)

            var events: [Event] = []
            if let lost = pending {
                events.append(.abandoned(type: lost.type, got: lost.data.count,
                                         expected: lost.length))
            }
            if pages == 0 {
                pending = nil
                events.append(.message(type: frame[5], seq: frame[3],
                                       body: head.prefix(length)))
            } else {
                pending = (frame[5], frame[3], length, head, pages)
                events.append(.started(type: frame[5], pages: pages, length: length))
            }
            return events
        }
    }

    /// Подтверждение принятой посылки.
    ///
    /// Собирается по образцу из `CEProtocolB.getSendData` для случая
    /// `CMD_APP_ACK_TYPE`: вид 4, номер посылки берётся у принятой,
    /// в теле единица — «принято без ошибок».
    static func acknowledgement(type: UInt8, seq: UInt8) -> Data {
        var frame = [UInt8](repeating: 0, count: frameSize)
        frame[0] = 0
        frame[1] = 1                 // тип устройства
        frame[2] = 0
        frame[3] = seq
        frame[4] = 4                 // вид: подтверждение
        frame[5] = type
        frame[8] = 1                 // длина тела
        frame[9] = 0
        frame[10] = 1                // принято без ошибок
        return Data(frame)
    }
    // MARK: - Разбор пачек

    /// Отметка смены стадии сна. Отрезок длится до следующей отметки,
    /// поэтому собирать их в отрезки можно только имея все сразу.
    struct SleepMark: Hashable {
        let time: Date
        let stage: SleepStage
    }

    struct Harvest {
        var heart: [MetricPoint] = []
        var oxygen: [MetricPoint] = []
        var hrv: [MetricPoint] = []
        var temperature: [MetricPoint] = []
        var steps: [StepDay] = []
        var sleepMarks: [SleepMark] = []

        init(heart: [MetricPoint] = [], oxygen: [MetricPoint] = [],
             hrv: [MetricPoint] = [], temperature: [MetricPoint] = [],
             steps: [StepDay] = [], sleepMarks: [SleepMark] = []) {
            self.heart = heart
            self.oxygen = oxygen
            self.hrv = hrv
            self.temperature = temperature
            self.steps = steps
            self.sleepMarks = sleepMarks
        }

        var isEmpty: Bool {
            heart.isEmpty && oxygen.isEmpty && hrv.isEmpty
                && temperature.isEmpty && steps.isEmpty && sleepMarks.isEmpty
        }
    }

    /// Стадии в том виде, в каком их нумерует браслет (`K6_Sleep`).
    /// Начало сна приложение само приравнивает к лёгкому — повторяем.
    static func stage(fromDevice value: UInt8) -> SleepStage? {
        switch value {
        case 1, 3: return .core
        case 2: return .deep
        case 5: return .rem
        case 4: return .awake
        default: return nil
        }
    }

    /// Превращает отметки в отрезки: каждый длится до следующей отметки.
    /// Последняя отметка — это пробуждение, длительности у неё нет.
    static func segments(from marks: [SleepMark]) -> [SleepSegment] {
        let sorted = Array(Set(marks)).sorted { $0.time < $1.time }
        guard sorted.count > 1 else { return [] }

        var result: [SleepSegment] = []
        for (mark, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.time.timeIntervalSince(mark.time)
            // Разрыв больше двух часов — это уже другая ночь, а не длинный отрезок.
            guard gap > 0, gap <= 2 * 3600 else { continue }
            result.append(SleepSegment(start: mark.time, end: next.time, stage: mark.stage))
        }
        return result
    }

    /// Пачка замеров: заголовок `<сколько> 00 <сколько>`, дальше записи подряд.
    /// У замеров запись 5 байт — время и значение; у активности 20 байт.
    static func parse(type: UInt8, body: Data) -> Harvest {
        var harvest = Harvest()
        guard body.count >= 3 else { return harvest }
        // Заголовок: сколько записей осталось всего, затем сколько в этой
        // посылке. Видно на выгрузке истории: 134 → 114 → 94 …, по 20 за раз.
        let count = Int(body[2]) > 0 ? Int(body[2]) : Int(body[0])
        guard count > 0 else { return harvest }
        let payload = Array(body.dropFirst(3))

        func records(size: Int) -> [[UInt8]] {
            var out: [[UInt8]] = []
            var offset = 0
            while offset + size <= payload.count, out.count < count {
                out.append(Array(payload[offset..<(offset + size)]))
                offset += size
            }
            return out
        }

        func time(_ bytes: [UInt8]) -> Date {
            let seconds = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                        | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }

        func plausible(_ date: Date) -> Bool {
            let year = Calendar.current.component(.year, from: date)
            return (2024...2035).contains(year)
        }

        switch type {
        case 7, 8, 17:                                        // пульс
            for r in records(size: 5) where (25...250).contains(r[4]) {
                let at = time(r)
                if plausible(at) { harvest.heart.append(MetricPoint(time: at, value: Double(r[4]))) }
            }
        case 20, 40:                                          // кислород
            for r in records(size: 5) where (50...100).contains(r[4]) {
                let at = time(r)
                if plausible(at) { harvest.oxygen.append(MetricPoint(time: at, value: Double(r[4]))) }
            }
        // Вариабельность приходит и разово (45), и историей (42); температура
        // тоже (46 и 47). Формат в паре одинаков, поэтому разбор общий.
        case 42, 45:                                          // вариабельность пульса, мс
            // Запись как у пульса: время и одно значение.
            for r in records(size: 5) where (5...200).contains(r[4]) {
                let at = time(r)
                if plausible(at) { harvest.hrv.append(MetricPoint(time: at, value: Double(r[4]))) }
            }
        case 46, 47:                                          // температура кожи, °C
            // Значение занимает два байта в десятых долях градуса —
            // `4b 01` это 33.1 °C.
            for r in records(size: 8) {
                let at = time(r)
                let celsius = Double(Int(r[4]) | Int(r[5]) << 8) / 10
                // Нижняя граница шире, чем у ношения (28°): здесь пропускаем
                // и остывший браслет, а «надет ли» решает уже хранилище.
                // Так измеритель видит и низкое значение и может сказать,
                // что браслет сняли, вместо того чтобы молча ничего не вернуть.
                guard plausible(at), (10...45).contains(celsius) else { continue }
                harvest.temperature.append(MetricPoint(time: at, value: celsius))
            }
        case 4, 5:                                            // активность за день
            for r in records(size: 20) {
                func number(_ at: Int) -> Int {
                    Int(r[at]) | Int(r[at + 1]) << 8 | Int(r[at + 2]) << 16 | Int(r[at + 3]) << 24
                }
                let at = time(r)
                let steps = number(4)
                guard plausible(at), steps > 0, steps < 200_000 else { continue }
                let day = Calendar.current.startOfDay(for: at)
                let entry = StepDay(day: day, steps: steps,
                                    meters: number(8), kcal: number(12) / 1000)
                if let i = harvest.steps.firstIndex(where: { $0.day == day }) {
                    if harvest.steps[i].steps < steps { harvest.steps[i] = entry }
                } else {
                    harvest.steps.append(entry)
                }
            }
        case 6:                                               // сон по стадиям
            harvest.sleepMarks = parseSleep(body: body)
        // Тип 43 (SLEEP_MONITOR_BAK) — сырьё мониторинга в другом формате,
        // 105 байт на посылку. Как сон его разбирать нельзя.
        default:
            break
        }
        return harvest
    }

    /// Сон приходит группами по 15 слотов.
    ///
    ///     байт 2      сколько групп
    ///     дальше по группам:
    ///       байт      сколько записей в группе полезны (до 15)
    ///       15 слотов по 5 байт: [тип][время, 4 байта младшим вперёд]
    ///
    /// Обрати внимание: здесь сперва тип, потом время — наоборот к замерам.
    static func parseSleep(body: Data) -> [SleepMark] {
        let bytes = [UInt8](body)
        guard bytes.count > 3 else { return [] }

        let groups = Int(bytes[2])
        var marks: [SleepMark] = []
        var offset = 3

        for _ in 0..<groups {
            guard offset < bytes.count else { break }
            let valid = min(Int(bytes[offset]), 15)
            offset += 1

            for slot in 0..<15 {
                guard offset + 5 <= bytes.count else { break }
                if slot < valid {
                    let kind = bytes[offset]
                    let seconds = UInt32(bytes[offset + 1]) | UInt32(bytes[offset + 2]) << 8
                                | UInt32(bytes[offset + 3]) << 16 | UInt32(bytes[offset + 4]) << 24
                    let at = Date(timeIntervalSince1970: TimeInterval(seconds))
                    let year = Calendar.current.component(.year, from: at)
                    if let stage = stage(fromDevice: kind), (2024...2035).contains(year) {
                        marks.append(SleepMark(time: at, stage: stage))
                    }
                }
                offset += 5
            }
        }
        return marks
    }
}
