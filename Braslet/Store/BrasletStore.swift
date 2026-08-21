import Foundation
import WidgetKit

/// Копит всё, что приезжает с браслета, и подмешивает к этому новые выгрузки.
///
/// База штатного приложения держит лишь последние дни, поэтому историю храним
/// у себя: каждая выгрузка добавляется к накопленному, повторы отсеиваются.
@MainActor
final class BrasletStore: ObservableObject {

    /// Один на всё приложение: в фоне данные приходят без участия экранов,
    /// и класть их надо в то же хранилище, что показывает интерфейс.
    static let shared = BrasletStore()

    @Published private(set) var nights: [SleepNight] = []
    @Published private(set) var steps: [StepDay] = []
    @Published private(set) var heart: [MetricPoint] = []
    @Published private(set) var oxygen: [MetricPoint] = []
    @Published private(set) var hrv: [MetricPoint] = []
    @Published private(set) var temperature: [MetricPoint] = []
    @Published private(set) var battery: Int?
    @Published private(set) var marks: [Mark] = []
    @Published private(set) var lastSync: Date?
    /// Дневные калории тренировок из «Здоровья» (тренировки с AirPods/Watch),
    /// старые дни впереди, сегодня в конце. Кормит фактор «Нагрузка»
    /// в восстановлении. Не персистим — источник HealthKit, читаем при входе.
    @Published private(set) var workoutLoad: [Double] = []

    /// Сеттер для `workoutLoad` — расширение `Store+Recovery` лежит в другом
    /// файле и приватный сеттер оттуда не виден.
    func updateWorkoutLoad(_ series: [Double]) {
        if workoutLoad != series { workoutLoad = series }
    }
    @Published var status: Status?

    struct Status: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private struct Persisted: Codable {
        var sleep: [SleepSegment] = []
        var steps: [StepDay] = []
        var heart: [MetricPoint] = []
        var oxygen: [MetricPoint] = []
        var hrv: [MetricPoint] = []
        var temperature: [MetricPoint] = []
        var battery: Int?
        var marks: [Mark] = []
        var lastSync: Date?

        init() {}

        // Декодируем каждое поле отдельно с запасным значением. Синтезированный
        // Codable падает на ОТСУТСТВУЮЩЕМ ключе (значение по умолчанию он не
        // берёт) — и добавление любого нового поля роняло декод старого файла,
        // отчего вся база сбрасывалась в пустую и перезаписывалась. Теперь
        // отсутствующий ключ просто берёт запасное, и добавлять поля безопасно.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sleep = try c.decodeIfPresent([SleepSegment].self, forKey: .sleep) ?? []
            steps = try c.decodeIfPresent([StepDay].self, forKey: .steps) ?? []
            heart = try c.decodeIfPresent([MetricPoint].self, forKey: .heart) ?? []
            oxygen = try c.decodeIfPresent([MetricPoint].self, forKey: .oxygen) ?? []
            hrv = try c.decodeIfPresent([MetricPoint].self, forKey: .hrv) ?? []
            temperature = try c.decodeIfPresent([MetricPoint].self, forKey: .temperature) ?? []
            battery = try c.decodeIfPresent(Int.self, forKey: .battery)
            marks = try c.decodeIfPresent([Mark].self, forKey: .marks) ?? []
            lastSync = try c.decodeIfPresent(Date.self, forKey: .lastSync)
        }

        var weight: Int { sleep.count + heart.count + hrv.count + temperature.count }
    }

    private var data = Persisted()

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("braslet.json")
    }

    /// Резервная копия — второй экземпляр на случай сбоя основного файла.
    private var backupURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("braslet.backup.json")
    }

    var isEmpty: Bool {
        nights.isEmpty && steps.isEmpty && heart.isEmpty
    }

    init() {
        load()
    }

    // MARK: - Приём выгрузок

    /// Подбирает файлы, положенные в папку приложения — «Файлами», по AirDrop
    /// или скриптом sync.sh с Mac. Повторы отсеиваются, так что перечитывать
    /// одно и то же безопасно.
    func importFromDocuments() {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }

        var added = 0
        for url in files {
            switch url.pathExtension.lowercased() {
            case "json": added += (try? absorb(BrasletJSON.parse(fileAt: url))) ?? 0
            case "csv":  added += (try? mergeSleep(SleepCSV.parse(fileAt: url))) ?? 0
            default: continue
            }
        }
        if added > 0 {
            status = Status(text: "Из папки приложения добавлено записей: \(added).",
                            isError: false)
            sendToHealth()
        }
    }

    /// Отправляет накопленное в «Здоровье».
    ///
    /// То, что приходит по Bluetooth, уходит туда сразу же. А вот принятое
    /// файлом раньше оседало только у нас — этого не хватало, когда данные
    /// забираются запасным путём, через копию iPhone.
    private func sendToHealth() {
        let nights = self.nights
        let harvest = BraceletProtocol.Harvest(heart: data.heart.suffix(500),
                                               oxygen: data.oxygen.suffix(500),
                                               steps: data.steps.suffix(30))
        Task {
            await HealthService.shared.write(harvest: harvest)
            _ = try? await HealthService.shared.write(nights: nights)
        }
    }

    /// Принимает то, что забрали с браслета напрямую, минуя Nx Wear.
    @discardableResult
    func absorbHarvest(heart: [MetricPoint],
                       oxygen: [MetricPoint],
                       steps: [StepDay],
                       sleep: [SleepSegment] = [],
                       hrv: [MetricPoint] = [],
                       temperature: [MetricPoint] = []) -> Int {
        var added = mergeSleep(sleep, finalize: false)
        added += mergePoints(heart.filter { Self.plausible($0, forHeart: true) },
                             into: \.heart)
        added += mergePoints(oxygen.filter { Self.plausible($0, forHeart: false) },
                             into: \.oxygen)
        added += mergePoints(hrv.filter { self.plausibleHRV($0.value) },
                             into: \.hrv)
        added += mergePoints(temperature.filter { Self.temperatureRange.contains($0.value) },
                             into: \.temperature)

        var byDay = Dictionary(uniqueKeysWithValues: data.steps.map { ($0.day, $0) })
        for day in steps where (byDay[day.day]?.steps ?? -1) < day.steps {
            byDay[day.day] = day
            added += 1
        }
        data.steps = byDay.values.sorted { $0.day < $1.day }

        rebuild()
        save()
        return added
    }

    /// Ставит метку события: время + переданное место + последние витальные.
    /// Витальные берём свежие (не старше 15 минут), иначе оставляем пустыми.
    func addMark(latitude: Double? = nil, longitude: Double? = nil) {
        func recent(_ points: [MetricPoint], within: TimeInterval = 900) -> Double? {
            guard let last = points.latest,
                  Date().timeIntervalSince(last.time) <= within else { return nil }
            return last.value
        }
        let mark = Mark(time: Date(),
                        latitude: latitude, longitude: longitude,
                        pulse: recent(heart).map(Int.init),
                        oxygen: recent(oxygen).map(Int.init),
                        hrv: recent(hrv).map(Int.init),
                        temperature: recent(temperature))
        data.marks.append(mark)
        rebuild()
        save()
    }

    // MARK: - Слияние

    @discardableResult
    private func absorb(_ snap: BrasletSnapshot) -> Int {
        var added = mergeSleep(snap.sleep, finalize: false)  // финализируем в конце

        // Шаги за день приходят накопительным итогом: побеждает больший.
        var byDay = Dictionary(uniqueKeysWithValues: data.steps.map { ($0.day, $0) })
        for day in snap.steps where (byDay[day.day]?.steps ?? -1) < day.steps {
            byDay[day.day] = day
            added += 1
        }
        data.steps = byDay.values.sorted { $0.day < $1.day }

        added += mergePoints(snap.heart, into: \.heart)
        added += mergePoints(snap.oxygen, into: \.oxygen)

        // Заряд из файла не берём: он живёт из потока браслета и всегда
        // свежее любого экспорта. Раньше импорт старого выгруза при каждом
        // открытии затирал живой заряд обратно на 43%.
        if data.battery == nil { data.battery = snap.battery }
        if data.lastSync == nil { data.lastSync = snap.generatedAt }

        rebuild()
        save()
        return added
    }

    @discardableResult
    /// `finalize: false` — только слить и отсортировать, без rebuild()/save():
    /// зовущий (absorbHarvest) финализирует сам один раз в конце, иначе на
    /// каждый пакет со сном шли двойная запись на диск и двойной reload виджета.
    private func mergeSleep(_ incoming: [SleepSegment], finalize: Bool = true) -> Int {
        var known = Set(data.sleep.map(Self.key))
        var added = 0
        for segment in incoming where !known.contains(Self.key(segment)) {
            known.insert(Self.key(segment))
            data.sleep.append(segment)
            added += 1
        }
        if added > 0 {
            data.sleep.sort { $0.start < $1.start }
            if finalize {
                rebuild()
                save()
            }
        }
        return added
    }

    /// То же самое на входе: невозможное не сохраняем вовсе.
    /// Вариабельность ниже пяти миллисекунд и выше двухсот физически
    /// не встречается.
    static let hrvRange: ClosedRange<Double> = 5...200

    /// Кожа надетого браслета греется телом до 31–34 °C. Всё, что холоднее
    /// 28°, — это воздух: браслет сняли, и он остыл до комнатного. Такие
    /// замеры отбрасываем, иначе в историю температуры лезет температура
    /// комнаты. Аппаратного флага «надет» у браслета нет, температура кожи —
    /// единственный доступный признак ношения.
    static let temperatureRange: ClosedRange<Double> = 28...42

    /// Надет ли браслет — судим по последней температуре кожи.
    var isWorn: Bool {
        guard let last = temperature.latest else { return false }
        return Self.temperatureRange.contains(last.value)
    }

    private static func plausible(_ point: MetricPoint, forHeart: Bool) -> Bool {
        forHeart ? (25...250).contains(point.value) : (50...100).contains(point.value)
    }

    /// HRV принимаем, если она в физдиапазоне И не резкий провал почти вдвое
    /// ниже недавней медианы. Такие «ямы» (вроде 32 при обычных 55–70) даёт
    /// потеря контакта при снятии браслета, а не настоящая вариабельность;
    /// честный послетренировочный спад (условно 50) остаётся. Пока истории
    /// мало — не судим, пропускаем всё.
    private func plausibleHRV(_ value: Double) -> Bool {
        guard Self.hrvRange.contains(value) else { return false }
        let recent = data.hrv.suffix(20).map(\.value).sorted()
        guard recent.count >= 8 else { return true }
        let median = recent[recent.count / 2]
        return value >= median * 0.55
    }

    private func mergePoints(_ incoming: [MetricPoint],
                             into keyPath: WritableKeyPath<Persisted, [MetricPoint]>) -> Int {
        var known = Set(data[keyPath: keyPath].map(\.time))
        var added = 0
        for point in incoming where !known.contains(point.time) {
            known.insert(point.time)
            data[keyPath: keyPath].append(point)
            added += 1
        }
        if added > 0 {
            data[keyPath: keyPath].sort { $0.time < $1.time }
        }
        return added
    }

    private static func key(_ s: SleepSegment) -> String {
        "\(Int(s.start.timeIntervalSince1970))-\(Int(s.end.timeIntervalSince1970))-\(s.stage.rawValue)"
    }

    func removeAll() {
        data = Persisted()
        rebuild()
        save()
    }

    // Историю НЕ ужимаем. Раньше здесь было `compact()`: всё старше текущего
    // месяца схлопывалось в одно среднее на месяц. Это убито намеренно —
    // поштучная история копится под будущие модели (годовые ряды для LSTM),
    // HRV-коридору нужны 60 дней поштучно, а объём копеечный: ~35 байт на
    // точку, поминутный пульс за год ≈ 18 МБ. Не возвращать.

    /// Живой заряд из потока браслета.
    ///
    /// Раньше заряд попадал сюда только при импорте копии Nx Wear и висел
    /// устаревшим — шапка показывала 43%, когда браслет уже сел до 19.
    func setBattery(_ percent: Int) {
        guard (0...100).contains(percent), data.battery != percent else { return }
        data.battery = percent
        battery = percent
        save()
        publishToWidget()
    }

    private func rebuild() {
        publishToWidget()
        // Сном считаем только эпизоды дольше полутора часов. Короткие
        // (дневная неподвижность, минутная дрёма) — не сон: разметка из DLOG
        // принимает их за сон, но настоящий сон у владельца всегда от
        // нескольких часов. Пульс из тех же минут сохраняется отдельно —
        // фильтруем только интерпретацию сна, не данные.
        nights = data.sleep.groupedIntoNights().filter { $0.asleepDuration >= 90 * 60 }
        steps = data.steps
        heart = data.heart
        oxygen = data.oxygen
        hrv = data.hrv
        temperature = data.temperature
        battery = data.battery
        marks = data.marks.sorted { $0.time > $1.time }
        lastSync = data.lastSync
    }

    /// Обновляет выжимку для виджета.
    ///
    /// Виджет живёт отдельным процессом и в наш контейнер заглянуть не может,
    /// поэтому текущие значения кладём в общий контейнер группы и просим
    /// систему перерисовать.
    private func publishToWidget() {
        let score = recovery
        let snapshot = WidgetSnapshot(
            recovery: score.factors.contains(where: \.available) ? score.value : nil,
            steps: data.steps.max(by: { $0.day < $1.day })?.steps,
            heart: data.heart.latest.map { Int($0.value) },
            oxygen: data.oxygen.latest.map { Int($0.value) },
            hrv: data.hrv.latest.map { Int($0.value) },
            temperature: data.temperature.latest?.value,
            battery: data.battery,
            sleep: nights.first?.asleepDuration,
            updated: Date())
        WidgetSnapshot.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Сохранение между запусками

    private func save() {
        do {
            let encoded = try JSONEncoder().encode(data)
            try encoded.write(to: fileURL, options: .atomic)
            // Дублируем в резервную копию, когда данных существенно — чтобы
            // случайное обнуление основного файла не стоило всей истории.
            if data.weight > 10 {
                try? encoded.write(to: backupURL, options: .atomic)
            }
        } catch {
            status = Status(text: "Не удалось сохранить: \(error.localizedDescription)",
                            isError: true)
        }
    }

    private func load() {
        // Читаем и основной, и резервный — берём тот, где данных больше.
        // Так восстановимся, даже если один файл побился или обнулился.
        let candidates = [Self.decode(fileURL), Self.decode(backupURL)].compactMap { $0 }
        if let best = candidates.max(by: { $0.weight < $1.weight }) {
            data = best
        }
        sanitise()
        rebuild()
    }

    private static func decode(_ url: URL) -> Persisted? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: raw)
    }

    /// Выбрасывает заведомо невозможные значения.
    ///
    /// Пульс в 25 тысяч ударов однажды уже приехал из-за неверного разбора —
    /// такие вещи должны отсекаться на входе, а не украшать график.
    private func sanitise() {
        // Разовая уборка: с 05:50 до 06:20 тринадцатого августа в историю
        // попадал счётчик из стандартного профиля, принятый за пульс.
        // Значения лежали в допустимом диапазоне, поэтому обычный фильтр
        // их не ловит — вычищаем по времени, один раз.
        let flag = "braslet.cleanedCounterGarbage2"
        if !UserDefaults.standard.bool(forKey: flag) {
            // Отсчёт от точно известной метки: 1786580165 это 03:16:05.
            let from = Date(timeIntervalSince1970: 1786589400)   // 13 авг, 05:50
            let till = Date(timeIntervalSince1970: 1786591800)   // 13 авг, 06:30
            let before = data.heart.count
            data.heart.removeAll { $0.time >= from && $0.time <= till }
            UserDefaults.standard.set(true, forKey: flag)
            if before != data.heart.count { save() }
        }

        let before = data.heart.count + data.oxygen.count
        data.heart.removeAll { !(25...250).contains($0.value) }
        data.oxygen.removeAll { !(50...100).contains($0.value) }
        data.hrv.removeAll { !Self.hrvRange.contains($0.value) }
        data.temperature.removeAll { !Self.temperatureRange.contains($0.value) }
        if before != data.heart.count + data.oxygen.count {
            save()
        }
    }
}
