import CoreBluetooth
import Foundation
import UIKit
import WidgetKit

/// Постоянный сбор данных с браслета — чтобы Nx Wear стал не нужен.
///
/// Браслет почти ничего не хранит: он отдаёт замеры по мере появления и
/// забывает их. Поэтому архивом должен быть тот, кто всё время слушает.
///
/// iOS позволяет приложению держать связь с BLE-устройством в фоне и даже
/// поднимает его заново после выгрузки из памяти — для этого объявлен режим
/// `bluetooth-central` и задан ключ восстановления.
@MainActor
final class BraceletCollector: NSObject, ObservableObject {

    static let shared = BraceletCollector()

    @Published private(set) var isConnected = false
    @Published private(set) var lastHeard: Date?
    /// Последний пришедший пульс — показывается во время тренировки.
    @Published private(set) var lastHeart: Double?
    @Published private(set) var receivedCount = 0
    @Published private(set) var state = "не запущен"

    /// Надет ли браслет. Когда снят — глушим автоматический съём эталонов
    /// (вариабельность и температуру мы меряем сами по таймеру), чтобы
    /// показания «на столе» не портили личный baseline восстановления.
    /// Историю из памяти браслета это не трогает — только живой автозамер.
    ///
    /// Хранится в общем контейнере группы (`WornStore`): тем же флагом рулит
    /// кнопка на виджете. Источник правды для гейта — `WornStore.value`.
    @Published var worn: Bool = WornStore.value {
        didSet {
            WornStore.value = worn
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Подтягивает флаг из общего контейнера — на случай, что его переключили
    /// с виджета, пока приложение было в фоне. Зовём при возвращении на экран.
    func refreshWorn() {
        let shared = WornStore.value
        if worn != shared { worn = shared }
    }

    private var central: CBCentralManager?
    private var device: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var reassembler = BraceletProtocol.Reassembler()
    private var sequence: UInt8 = 100        // свой диапазон, чтобы не спорить с Nx Wear

    private let store = BrasletStore.shared
    private let deviceName = "B8"
    private let rememberedKey = "braslet.peripheral"

    private static let service = CBUUID(string: "F618")
    // Стандартный профиль 180D у браслета есть, но в его характеристике
    // лежит не пульс, а счётчик: значения монотонно росли от 24 до 230
    // и начинали заново. Пользоваться им нельзя.
    private static let notifyChar = CBUUID(string: "B001")
    private static let writeCharUUID = CBUUID(string: "B002")

    /// Запускается один раз при старте приложения.
    func start() {
        guard central == nil else { return }
        state = "запускаюсь"
        central = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "braslet.collector"])
        startWatchdog()
        startSyncLoop()

        // При возвращении в приложение проверяем связь сразу, не дожидаясь
        // сторожа: человек открыл экран и хочет видеть свежее, а не ждать
        // до пяти минут.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in self?.reconnectIfNeeded(reason: "открыли приложение") }
        }
    }

    /// Опрос возможностей.
    ///
    /// Неподдерживаемую команду браслет молча пропускает, поддерживаемую —
    /// подтверждает. Так вскрылось, что уведомлений о сообщениях у него нет.
    /// Значит, по списку можно узнать, что он умеет на самом деле.
    ///
    /// Спрашиваем запросом (вид 3), а не командой: он ничего не меняет.
    func probeCapabilities() {
        let candidates: [(UInt8, String)] = [
            (11, "поиск телефона"), (14, "управление музыкой"),
            (18, "давление"), (19, "ЭКГ"), (26, "QR-код"),
            (44, "жесты"), (45, "вариабельность"), (46, "температура"),
            (61, "виды спорта"), (62, "макс. пульс"), (66, "плавание"),
            (67, "GPS"), (103, "язык"), (105, "погода"), (106, "будильники"),
            (111, "цели"), (113, "музыка на экране"), (114, "напоминание сидеть"),
            (115, "не беспокоить"), (116, "снимок встряхиванием"),
            (117, "управление звонком"), (119, "выключение"),
            (121, "единицы"), (125, "цель-уведомление"), (126, "напоминание пить"),
            (127, "поворот запястья"), (128, "автозамеры"), (129, "настройки часов"),
            (131, "циферблаты"), (133, "женское здоровье"), (135, "контакты"),
            (139, "погода вживую"), (140, "фото-циферблат"), (141, "заставка"),
            (143, "игра"), (157, "рука"), (158, "подсветка"),
            (160, "ночной режим"), (161, "яркость"), (162, "температура тела"),
        ]

        journal.add("═══ опрос возможностей: \(candidates.count) команд ═══")
        Task { [weak self] in
            for (code, name) in candidates {
                guard let self, self.isConnected else { return }
                self.journal.add("проверяю \(code) — \(name)")
                self.request(code)
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
            self?.journal.add("═══ опрос закончен ═══")
        }
    }

    /// Проверка датчиков, которых мы не используем: давление, вариабельность
    /// пульса, температура.
    ///
    /// На простой запрос все трое ответили пустым пакетом — это не отказ,
    /// а «мерить нечего»: так же молчит пульс, пока не включён датчик.
    /// Поэтому здесь тот же порядок, что и у замера пульса: разрешить
    /// передачу, включить датчик, подождать, выключить.
    func probeSensors() {
        let sensors: [(UInt8, String)] = [(18, "давление"), (45, "вариабельность"),
                                          (46, "температура")]
        Task { [weak self] in
            guard let self else { return }
            journal.add("═══ проверка датчиков ═══")
            for (code, name) in sensors {
                guard isConnected else { return }
                journal.add("── \(name): включаю датчик")
                send(109, [1])
                try? await Task.sleep(nanoseconds: 300_000_000)
                send(code, [1])
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                send(code, [0])
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                journal.add("── \(name): датчик выключен")
            }
            send(109, [0])
            journal.add("═══ проверка датчиков закончена ═══")
        }
    }

    /// Раз в полчаса просим у браслета накопленное.
    ///
    /// Сам он историю не шлёт: за целую ночь при живой связи пришли только
    /// служебные посылки, а замеры пульса и кислорода — ни одного. Отдаёт он
    /// их лишь в ответ на команду синхронизации, а её мы раньше слали только
    /// при подключении. Связь держалась всю ночь — и синхронизации не было ни разу.
    private func startSyncLoop() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_800_000_000_000)
                guard let self, self.isConnected, self.busy == nil else { continue }
                self.journal.add("плановая синхронизация")
                self.send(109, [1])
                self.send(110, Self.syncPayload)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.request(9)

                // Вариабельность и температуру браслет сам не меряет —
                // для них нет автоматического режима, как у пульса.
                // Раз в час снимаем их сами: чаще незачем, обе меняются
                // медленно, а датчик каждый раз горит почти минуту.
                if WornStore.value, Date().timeIntervalSince(self.lastExtraMeasure) > 3600 {
                    // Час отсчитываем от УДАЧНОГО замера: если сенсор был занят
                    // (юзер тапнул «измерить») и замер не прошёл, не проглатываем
                    // целый час, а пробуем в следующую синхронизацию.
                    var measured = false
                    if let value = await self.measureHRV() {
                        self.keep(value, as: \.hrv); measured = true
                    }
                    // Температуру — только когда браслет прогрелся до кожи после
                    // надевания (~20 мин): раннее значение занижено и испортило
                    // бы baseline и восстановление.
                    if WornStore.temperatureSettled,
                       let value = await self.measureTemperature() {
                        self.keep(value, as: \.temperature); measured = true
                    }
                    if measured { self.lastExtraMeasure = Date() }
                }
            }
        }
    }

    private var lastExtraMeasure: Date {
        get { UserDefaults.standard.object(forKey: "braslet.lastExtra") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "braslet.lastExtra") }
    }

    /// Кладёт разовый замер в хранилище тем же путём, что и пришедшее само.
    func keep(_ value: Double, as kind: WritableKeyPath<BraceletProtocol.Harvest, [MetricPoint]>) {
        var harvest = BraceletProtocol.Harvest()
        harvest[keyPath: kind] = [MetricPoint(time: Date(), value: value)]
        store.absorbHarvest(heart: harvest.heart, oxygen: harvest.oxygen,
                            steps: [], hrv: harvest.hrv,
                            temperature: harvest.temperature)
        Task { await HealthService.shared.write(harvest: harvest) }
    }

    /// Проверяет связь и подключается, если её нет.
    func reconnectIfNeeded(reason: String) {
        guard let manager = central, manager.state == .poweredOn, !isConnected else { return }
        journal.add("\(reason): связи нет, подключаюсь")
        if let device {
            manager.connect(device, options: nil)
        } else {
            attach(with: manager)
        }
    }

    /// Сторож связи.
    ///
    /// Одной заявки на подключение мало: если она почему-то не срабатывает,
    /// повторять её некому, и приложение молча остаётся без браслета до
    /// перезапуска. Поэтому раз в полчаса проверяем и пробуем заново.
    ///
    /// Чаще не нужно: при обычном разрыве заявка отрабатывает сама и связь
    /// возвращается сразу, а при открытии приложения проверка идёт мгновенно.
    /// Сторож — подстраховка на редкий случай, и будить ради неё радио
    /// каждые несколько минут значит зря есть батарею.
    private func startWatchdog() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 1_800_000_000_000)
                guard let self else { return }
                self.reconnectIfNeeded(reason: "сторож")
            }
        }
    }

    // MARK: - Поиск и подключение

    private func attach(with manager: CBCentralManager) {
        // Пока браслет подключён к системе, он молчит в эфире — сперва
        // спрашиваем уже подключённые, потом вспоминаем прошлый, и лишь
        // затем слушаем эфир.
        let connected = manager.retrieveConnectedPeripherals(withServices: [Self.service])
        if let found = connected.first(where: { $0.name == deviceName }) ?? connected.first {
            connect(found, with: manager, how: "уже на связи с системой")
            return
        }

        if let saved = UserDefaults.standard.string(forKey: rememberedKey),
           let uuid = UUID(uuidString: saved),
           let known = manager.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(known, with: manager, how: "по памяти о прошлом сеансе")
            return
        }

        state = "ищу браслет"
        manager.scanForPeripherals(withServices: nil)
    }

    private let journal = Journal.shared

    private func connect(_ peripheral: CBPeripheral,
                         with manager: CBCentralManager, how: String) {
        journal.add("подключаюсь: \(how)")
        greeted = false          // новое подключение — поздороваемся заново
        device = peripheral
        peripheral.delegate = self
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: rememberedKey)
        state = "подключаюсь (\(how))"
        manager.stopScan()
        // Заявка на подключение живёт бесконечно: если браслет уйдёт из зоны,
        // iOS сама восстановит связь, когда он вернётся.
        manager.connect(peripheral, options: nil)
    }

    // MARK: - Разовые команды

    /// Что сейчас делаем по кнопке — показывается в карточке.
    @Published private(set) var busy: String?

    /// Ловит все посылки во время замера — чтобы отсеять старые записи.
    private var freshSink: ((UInt8, Data) -> Void)?
    /// Пока идёт замер, не гасим датчики страховкой при переподключении.
    private var measuring = false

    /// Разовый замер пульса — точно по перехвату штатного приложения:
    ///
    ///     → 109 = 01     разрешение на передачу
    ///     →  24 = 01     старт
    ///     ←   7 ×N       поток значений секунд тридцать
    ///     →  24 = 00     стоп
    ///     → 109 = 00     запрет
    ///
    /// Ответ приходит под номером 7, а не 24 — на этом я сначала и споткнулся.
    /// Из потока берём медиану: он заметно дёргается от движений руки.
    func measureHeart() async -> Int? {
        guard isConnected, busy == nil else { return nil }
        busy = "меряю, это займёт полминуты"
        measuring = true
        defer {
            busy = nil
            measuring = false
        }

        var collected: [Int] = []
        freshSink = { [weak self] type, body in
            guard type == 7 else { return }
            let harvest = BraceletProtocol.parse(type: type, body: body)
            for point in harvest.heart where (25...250).contains(point.value) {
                collected.append(Int(point.value))
            }
            self?.busy = "меряю, замеров: \(collected.count)"
        }

        journal.add("замер пульса: старт")
        send(109, [1])
        send(24, [1])

        try? await Task.sleep(nanoseconds: 30_000_000_000)

        send(24, [0])
        send(109, [0])
        freshSink = nil

        guard !collected.isEmpty else {
            journal.add("замер пульса: значений не пришло")
            return nil
        }

        // Медиана устойчивее среднего: одиночные выбросы от движения
        // руки её не утягивают.
        let sorted = collected.sorted()
        let value = sorted[sorted.count / 2]
        journal.add("замер пульса: \(collected.count) значений, медиана \(value)")
        return value
    }

    /// Замер вариабельности пульса.
    ///
    /// Браслет отвечает одним значением примерно через полминуты после
    /// включения датчика — поэтому ждём дольше, чем при пульсе, и берём
    /// последнее пришедшее.
    func measureHRV() async -> Double? {
        await measureStream(command: 45, name: "вариабельность", seconds: 45) {
            $0.hrv
        }
    }

    /// Замер температуры кожи.
    ///
    /// Значения идут потоком примерно раз в четыре секунды, поэтому берём
    /// медиану: первые замеры приходят, пока датчик ещё прогревается.
    func measureTemperature() async -> Double? {
        await measureStream(command: 46, name: "температура", seconds: 25) {
            $0.temperature
        }
    }

    /// Общий порядок для датчиков, которые шлют поток значений: разрешить
    /// передачу, включить, подождать, выключить. Без `109` браслет молчит,
    /// а без выключения датчик остаётся гореть и жжёт батарею.
    private func measureStream(command: UInt8, name: String, seconds: Double,
                               pick: @escaping (BraceletProtocol.Harvest) -> [MetricPoint])
        async -> Double? {
        guard isConnected, busy == nil else { return nil }
        busy = "меряю \(name)"
        measuring = true
        defer {
            busy = nil
            measuring = false
        }

        var collected: [Double] = []
        freshSink = { [weak self] type, body in
            guard type == command else { return }
            let values = pick(BraceletProtocol.parse(type: type, body: body)).map(\.value)
            collected.append(contentsOf: values)
            if !values.isEmpty { self?.busy = "меряю \(name): \(collected.count)" }
        }

        journal.add("замер \(name): старт")
        send(109, [1])
        send(command, [1])

        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        send(command, [0])
        send(109, [0])
        freshSink = nil

        guard !collected.isEmpty else {
            journal.add("замер \(name): значений не пришло")
            return nil
        }
        let sorted = collected.sorted()
        let value = sorted[sorted.count / 2]
        journal.add("замер \(name): \(collected.count) значений, медиана \(value)")
        return value
    }

    func measureOxygen() async -> Int? {
        await measure(start: 20, payload: [1], stop: 20, stopPayload: [0],
                      replies: [20])
    }

    /// Включает датчик, ждёт значение и гасит обратно.
    ///
    /// Всё через то же единственное соединение: отдельное подключение
    /// для замеров конфликтовало с постоянным и глушило датчик.
    private func measure(start: UInt8, payload: [UInt8],
                         stop: UInt8, stopPayload: [UInt8],
                         replies: [UInt8],
                         alsoTry: (UInt8, [UInt8])? = nil,
                         after: Double = 0) async -> Int? {
        guard isConnected, busy == nil else { return nil }
        busy = "меряю, это займёт секунд двадцать"
        measuring = true
        defer {
            busy = nil
            measuring = false
        }

        journal.add("замер: запускаю \(start)")
        send(109, [1])                       // без разрешения браслет молчит
        send(start, payload)

        // Запасная команда на случай, если первая не та.
        if let alsoTry {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
                guard let self, self.busy != nil else { return }
                self.journal.add("замер: пробую ещё команду \(alsoTry.0)")
                self.send(alsoTry.0, alsoTry.1)
            }
        }

        let value = await waitForFresh(replies, seconds: 45)

        send(stop, stopPayload)              // гасим датчик
        if let alsoTry { send(alsoTry.0, [0]) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return value
    }

    /// Ждёт замер, сделанный **только что**.
    ///
    /// Браслет в ответ охотно присылает старые записи из своей истории —
    /// показать их как свежий замер значит соврать. Поэтому берём только
    /// запись со свежей меткой времени, остальные пропускаем.
    private func waitForFresh(_ types: [UInt8], seconds: Double) async -> Int? {
        await withCheckedContinuation { (c: CheckedContinuation<Int?, Never>) in
            var finished = false

            freshSink = { [weak self] type, body in
                guard !finished, types.contains(type) else { return }
                // 255 — наша метка для стандартного профиля: там уже готовое число.
                if type == 255, let bpm = body.first {
                    finished = true
                    self?.freshSink = nil
                    self?.journal.add("замер: стандартный профиль дал \(bpm)")
                    c.resume(returning: Int(bpm))
                    return
                }
                let harvest = BraceletProtocol.parse(type: type, body: body)
                // Кислород парсер кладёт в .oxygen, а не .heart — без него замер
                // SpO₂ (тип 20) всегда возвращал nil: сенсор горел зря 45 секунд.
                let fresh = (harvest.heart + harvest.oxygen).filter {
                    Date().timeIntervalSince($0.time) < 120
                }
                guard let newest = fresh.max(by: { $0.time < $1.time }) else {
                    self?.journal.add("замер: пришло \(type), но записи старые")
                    return
                }
                finished = true
                self?.freshSink = nil
                self?.journal.add("замер: свежее значение \(Int(newest.value))")
                c.resume(returning: Int(newest.value))
            }

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !finished else { return }
                finished = true
                self?.freshSink = nil
                self?.journal.add("замер: свежего значения так и не пришло")
                c.resume(returning: nil)
            }
        }
    }
    /// Экран по повороту запястья. Расписание не нужно — окно на все сутки.
    /// Взводит жест встряхивания (код 116). В режиме съёмки браслет шлёт
    /// нам код 116 при каждой тряске — это можно ловить как жест. Экран
    /// браслета при этом ничего не показывает (проверено владельцем).
    /// Разведка: приходит ли входящий 116 и остаётся ли взведённым.
    func armShake(_ on: Bool) {
        send(116, [on ? 1 : 0])
        journal.add(on ? "тряска взведена (116=1)" : "тряска снята (116=0)")
    }

    // MARK: - Жест встряхивания

    private var lastArmAt = Date.distantPast
    private var shakeCount = 0
    private var shakeTask: Task<Void, Never>?

    /// Пока открыт экран камеры-затвора, тряска идёт сюда (спуск), а не на
    /// обычное действие. Ставит и снимает сам экран камеры.
    var cameraShutterHandler: (() -> Void)?

    /// Экран камеры взводит тряску принудительно, даже если жест выключен.
    func armShakeForCamera(_ on: Bool) {
        armShake(on)
        if on { lastArmAt = Date() } else { updateShakeArming() }
    }

    /// Взводит или снимает жест по настройкам.
    func updateShakeArming() {
        guard isConnected else { return }
        let shouldArm = ShakeSettings.active
        armShake(shouldArm)
        if shouldArm { lastArmAt = Date() }
    }

    /// Пришла тряска (входящий 116). Копим ~1.2 сек, чтобы отличить одиночную
    /// от двойной, затем выполняем настроенное действие.
    private func onShake() {
        // Эхо сразу после взвода — не тряска.
        guard Date().timeIntervalSince(lastArmAt) > 1.5 else { return }

        // Открыт экран камеры — каждая тряска сразу спускает затвор, без
        // разбора одиночная/двойная.
        if let shutter = cameraShutterHandler {
            shutter()
            return
        }

        guard ShakeSettings.active else { return }
        shakeCount += 1
        shakeTask?.cancel()
        shakeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled, let self else { return }
            let double = self.shakeCount >= 2
            self.shakeCount = 0
            self.runShakeAction(double ? ShakeSettings.doubleAction
                                       : ShakeSettings.singleAction)
        }
    }

    private func runShakeAction(_ action: ShakeSettings.Action) {
        journal.add("тряска → \(action.title)")
        switch action {
        case .none: break
        case .findPhone: PhoneFinder.shared.toggle()
        case .dictaphone: Dictaphone.shared.toggle()
        case .fakeCall: FakeCall.shared.ring()
        case .mark:
            MarkLocator.shared.fetch { [weak self] location in
                self?.store.addMark(latitude: location?.coordinate.latitude,
                                    longitude: location?.coordinate.longitude)
            }
        }
    }

    func setWristRaise(_ on: Bool) {
        send(127, [on ? 1 : 0, 0, 0, 23, 59, 5])
    }

    /// Оповещать ли о входящем звонке.
    func setCallAlerts(_ on: Bool) {
        send(122, [on ? 1 : 0])
    }

    // Уведомлений о сообщениях у этой прошивки нет.
    // Команда 123 (MESSAGE_ALARM) — единственная, которую браслет не
    // подтверждает, при том что соседние 124 и 107 подтверждает исправно.
    // Команда 107 с текстом принимается, но на экран ничего не выводится.
    // Итог: браслет показывает только входящий звонок, и тот приходит
    // стандартной службой iOS (ANCS), а не через этот протокол.

    /// Очередь записи. Писать кадры вплотную нельзя: подряд идущие команды
    /// переполняют очередь Bluetooth и часть просто теряется — из-за этого
    /// тренировка не включала передачу пульса.
    private var outbox: [Data] = []
    private var draining = false

    private func send(_ command: UInt8, _ payload: [UInt8]) {
        journal.add("→ \(command): \(payload.map { String(format: "%02x", $0) }.joined())")
        sequence = sequence &+ 1
        outbox += BraceletProtocol.frames(command: command,
                                          payload: payload, sequence: sequence)
        drain()
    }

    /// Подтверждение уходит вне очереди — оно должно успеть вовремя.
    private func acknowledge(type: UInt8, seq: UInt8) {
        guard let device, let characteristic = writeChar else { return }
        device.writeValue(BraceletProtocol.acknowledgement(type: type, seq: seq),
                          for: characteristic, type: .withoutResponse)
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        Task { [weak self] in
            while let next = self?.outbox.first {
                guard let self, let device = self.device,
                      let characteristic = self.writeChar else { break }
                self.outbox.removeFirst()
                device.writeValue(next, for: characteristic, type: .withoutResponse)
                try? await Task.sleep(nanoseconds: 40_000_000)
                _ = next
            }
            self?.draining = false
        }
    }

    /// Собирает сборную посылку — так устроена команда `110`.
    ///
    /// Разобрана из `K6_MixInfoStruct`: сперва общая длина и число свойств,
    /// затем свойства подряд, у каждого своя длина, номер и тело.
    /// Прежде мы слали сюда двенадцать байт со старого перехвата: они
    /// оказались верной посылкой, но всего с двумя свойствами из семи.
    static func mixInfo(_ properties: [(UInt8, [UInt8])]) -> [UInt8] {
        var body: [UInt8] = []
        for (type, data) in properties {
            let length = data.count + 3
            body += [UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF), type]
            body += data
        }
        let total = body.count + 1
        return [UInt8(total & 0xFF), UInt8((total >> 8) & 0xFF),
                UInt8(properties.count)] + body
    }

    private static func le32(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
         UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    private static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    /// Время в том виде, в каком его ждёт браслет.
    private static var timeBytes: [UInt8] {
        le32(Int(Date().timeIntervalSince1970))
            + le32(TimeZone.current.secondsFromGMT()) + [3]
    }

    /// Профиль владельца. Значения только для расчётов, нигде не показываются.
    private static var profileBytes: [UInt8] {
        [0x4e, 0xe9, 0x09, 0x00, 1, UInt8(Profile.age),
         UInt8(Profile.heightCm), UInt8(Int(Profile.weightKg)), 0]
    }

    /// Цели: шаги, метры, килокалории, минуты сна, минуты нагрузки.
    private static var goalBytes: [UInt8] {
        le32(10_000) + le32(8_000) + le32(300) + le16(480) + le16(30)
    }

    /// Полное приветствие — те же семь свойств, что шлёт штатное приложение.
    private static var syncPayload: [UInt8] {
        mixInfo([(102, profileBytes),
                 (104, timeBytes),
                 (124, [1, 0xFF, 0xFF, 0, 0]),
                 (103, [0]),
                 (109, [1]),
                 (111, goalBytes),
                 (120, [0, 0])])
    }

    /// Запрос данных: вид посылки 3 означает «пришли мне вот это».
    /// В SDK так устроены все «get»-вызовы, например `e.h(3, 114)`.
    private func request(_ type: UInt8) {
        guard let device, let characteristic = writeChar else { return }
        sequence = sequence &+ 1
        var frame = [UInt8](repeating: 0, count: BraceletProtocol.frameSize)
        frame[1] = 1
        frame[3] = sequence
        frame[4] = 3
        frame[5] = type
        journal.add("? запрашиваю \(type)")
        device.writeValue(Data(frame), for: characteristic, type: .withoutResponse)
    }

    /// Первичная настройка, как её делает штатное приложение при сопряжении.
    ///
    /// Мы её раньше не слали вовсе — просто подключались к уже настроенному
    /// браслету. Пока Nx Wear был жив, настройки держались им. Время особенно
    /// важно: по нему браслет метит все записи, и уплывшие часы испортят
    /// и сон, и замеры.
    private func introduce() {
        let now = UInt32(Date().timeIntervalSince1970)
        // secondsFromGMT() отрицателен в западных зонах — прямой UInt32(...)
        // крашил. Кодируем знаковое смещение как два дополнения (те же 4 байта).
        let offset = UInt32(bitPattern: Int32(TimeZone.current.secondsFromGMT()))
        send(104, [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
                   UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
                   UInt8(offset & 0xFF), UInt8((offset >> 8) & 0xFF),
                   UInt8((offset >> 16) & 0xFF), UInt8((offset >> 24) & 0xFF),
                   3])

        // Профиль: идентификатор, пол, возраст, рост, вес — как в перехвате.
        send(102, [0x4e, 0xe9, 0x09, 0x00, 1,
                   UInt8(min(255, max(0, Profile.age))),
                   UInt8(min(255, max(0, Profile.heightCm))),
                   UInt8(min(255, max(0, Int(Profile.weightKg)))), 0])

        // Автоматические замеры (`K6_DATA_TYPE_HEART_AUTO_SWITCH`, 8 байт):
        // пульс включён, раз в полчаса, кислород тоже.
        //
        // Второй байт — «круглосуточно» — держим нулём. Штатное приложение
        // ставит там ноль **всегда**, даже когда пользователь включает
        // автозамеры: `sendHeartAutoSwitch(включено, 0, интервал, кислород)`.
        // Мы слали единицу, и ночь не размечалась ни разу: похоже, при
        // круглосуточном режиме прошивка не отделяет сон от бодрствования.
        //
        // Мы эту команду не слали никогда, а при каждом подключении гасили
        // датчики «страховкой» — и, похоже, этим сами отключили ночные
        // измерения. Ночью пульс стоял ровно на 66 все 479 записей подряд,
        // то есть браслет отдавал последнее известное значение, а не мерил.
        // Без пульса ему нечем размечать сон.
        // Тест «круглосуточно=1» (ловить дневной сон) ПРОВАЛИЛСЯ: пару ночей
        // подряд ночь размечалась огрызком (~4ч из 12–13) — в 24-часовом
        // режиме прошивка не отделяет сон от бодрствования. Владелец выбрал
        // ночь в приоритете, вернули второй байт в 0. Дневной сон при этом
        // браслет не ловит — осознанный размен.
        send(128, Self.heartAutoConfig)
    }

    /// Эталон авторежима пульса/кислорода (команда 128): [autoHR, круглосуточно,
    /// интервал, autoO2, 0,0,0,0]. Тот же массив шлём при настройке и сверяем
    /// с эхом в описи кода 9 — если браслет сбросил, переприменяем.
    static let heartAutoConfig: [UInt8] = [1, 0, 30, 1, 0, 0, 0, 0]

    /// Поздоровались ли уже в этом подключении. Гейт против двойного greet()
    /// (а с ним 109/110/request(9)): при переподключении система порой отдаёт
    /// два цикла discovery, из-за чего опись кода 9 запрашивалась дважды.
    private var greeted = false

    private func greet() {
        guard !greeted else { return }
        greeted = true
        introduce()
        // Страховка: если прошлый замер оборвался, датчик мог остаться гореть.
        // Гасим оба на всякий случай — команда безобидная.

        send(109, [1])                 // SET_DATA_SWITCH — разрешаем слать данные
        send(110, Self.syncPayload)    // APP_SYNC — забираем накопленное

        // Запрос выгрузки накопленного. Настоящий триггер — вид 3, тип 9
        // (`DEV_SYNC`), а вовсе не тип 6: в Nx Wear это `requestDataSync()`
        //   → `sendDATA_TYPE_DEV_SYNC()` → `push(new CEDevData(3, 9))`.
        // Браслет в ответ вываливает опись и всю несобранную историю, включая
        // сон. Мы полгода просили тип 6 и получали пустоту, потому что сон
        // приходит не по прямому запросу, а внутри этой общей выгрузки.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.request(9)
        }

        // Взводим жест встряхивания, если включён в настройках.
        updateShakeArming()

        state = "слушаю браслет"
        journal.add("связь установлена")
    }

    /// Отметки сна копим за весь сеанс: отрезок длится до следующей отметки,
    /// а она может приехать другой посылкой.
    private var sleepMarks: Set<BraceletProtocol.SleepMark> = []

    /// Разбирает сборную посылку (`K6_MixInfoStruct`) на пары «номер, тело».
    /// Заголовок: два байта длины, байт числа свойств; дальше каждое свойство
    /// начинается со своей длины (2 байта) и номера.
    static func mixProperties(_ body: Data) -> [(UInt8, [UInt8])] {
        let bytes = [UInt8](body)
        guard bytes.count >= 3 else { return [] }
        let count = Int(bytes[2])
        var out: [(UInt8, [UInt8])] = []
        var i = 3
        for _ in 0..<count {
            guard i + 3 <= bytes.count else { break }
            let length = Int(bytes[i]) | Int(bytes[i + 1]) << 8
            guard length >= 3, i + length <= bytes.count else { break }
            out.append((bytes[i + 2], Array(bytes[(i + 3)..<(i + length)])))
            i += length
        }
        return out
    }

    /// Единая точка обновления заряда: и из отдельного пакета, и из описи.
    private func applyBattery(_ level: Int) {
        let previous = store.battery
        store.setBattery(level)
        if level < 20, previous == nil || previous! >= 20 {
            Notifier.lowBattery(level)
        }
    }

    // MARK: - Своя разметка сна из DLOG

    private var dlogRecords: [[UInt8]] = []
    private var dlogStageTask: Task<Void, Never>?

    /// Копит записи DLOG. Пачка приходит подряд многими пакетами, поэтому
    /// разметку запускаем не сразу, а через паузу тишины — когда пачка
    /// дособралась. Клок-walk внутри требует весь поток разом.
    private func accumulateDLOG(_ body: Data) {
        let bytes = [UInt8](body)
        guard bytes.count >= 3 else { return }
        let count = Int(bytes[2])
        var i = 3
        for _ in 0..<count {
            guard i + 8 <= bytes.count else { break }
            dlogRecords.append(Array(bytes[i..<(i + 8)]))
            i += 8
        }
        // Защита от бесконечного потока.
        if dlogRecords.count > 200_000 {
            dlogRecords.removeFirst(dlogRecords.count - 200_000)
        }
        lastHeard = Date()

        dlogStageTask?.cancel()
        dlogStageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.stageDLOG()
        }
    }

    /// Разбирает накопленный DLOG: сохраняет плотный пульс и размечает сон.
    ///
    /// Ничего не выбрасываем. DLOG идёт и днём — это реальная поминутная
    /// история пульса, куда плотнее наших часовых замеров, поэтому пульс
    /// сохраняем всегда. Сон размечаем из тех же минут; день от ночи
    /// отделяет группировка по двухчасовым разрывам, а не отсев данных.
    private func stageDLOG() {
        guard !dlogRecords.isEmpty else { return }
        let records = dlogRecords
        dlogRecords = []

        // Сохраняем сырой поток в файл ДО разбора — чтобы никогда не терять
        // ночь и мочь перепарсить, если разбор поправим. Доступно через «Файлы».
        saveRawDLOG(records)

        let mins = SleepStaging.minutes(from: SleepStaging.samples(from: records))
        guard !mins.isEmpty else { return }

        // Пульс из DLOG — плотная история, храним. Сон из DLOG НЕ размечаем:
        // браслет сам шлёт готовый размеченный сон кодом 6 (многокусково, когда
        // ночь кончилась), и он достоверный. Своя разметка была мусором.
        let heart = mins.map { MetricPoint(time: $0.time, value: Double($0.pulse)) }

        journal.add("DLOG: \(mins.count) минут пульса")
        let added = store.absorbHarvest(heart: heart, oxygen: [], steps: [])
        guard added > 0 else { return }

        let all = store.nights
        Task {
            await HealthService.shared.write(
                harvest: BraceletProtocol.Harvest(heart: heart))
            _ = try? await HealthService.shared.write(nights: all)
        }
    }

    /// Пишет сырой DLOG-батч в файл (hex, по записи в строку) в папку
    /// приложения — доступны через «Файлы». Храним ВСЁ, без ротации: это
    /// посекундный пульс+движение, самое ценное сырьё под будущие модели
    /// (годовые ряды для LSTM). Объём копеечный: 20 батчей ≈ 26 КБ, за год —
    /// единицы МБ. Прежняя ротация «20 последних» уже стёрла первую неделю.
    private func saveRawDLOG(_ records: [[UInt8]]) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let dir = docs.appendingPathComponent("dlog", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970)
        let hex = records.map { $0.map { String(format: "%02x", $0) }.joined() }
            .joined(separator: "\n")
        try? hex.write(to: dir.appendingPathComponent("dlog-\(stamp).hex"),
                       atomically: true, encoding: .utf8)
    }

    private func absorb(type: UInt8, body: Data) {
        // Заряд (тип 3) идёт мимо общего разбора: это не история, а текущее
        // состояние. Пуш — только при пересечении порога вниз, чтобы одно
        // и то же не приходило каждый час.
        if type == 3, let level = body.first, (0...100).contains(level) {
            applyBattery(Int(level))
            return
        }

        // Опись `DEV_SYNC` приходит при каждом подключении и несёт свежий
        // заряд свойством 3. Отдельный пакет заряда браслет шлёт редко, раз
        // в час, поэтому берём его отсюда — иначе шапка висела бы на старом
        // значении до следующего часа.
        if type == 9 {
            for (prop, data) in Self.mixProperties(body) {
                switch prop {
                case 3:      // заряд
                    if let level = data.first, (0...100).contains(level) {
                        applyBattery(Int(level))
                    }
                case 128:    // эхо авторежима пульса/кислорода
                    // Если браслет сбросил настройки (после разряда или
                    // переподключения) — молча переприменяем эталон, иначе
                    // ночной пульс/кислород тихо перестанут мериться.
                    if data != Self.heartAutoConfig {
                        journal.add("авторежим разошёлся ("
                                  + data.map { String(format: "%02x", $0) }.joined()
                                  + ") — переприменяю")
                        send(128, Self.heartAutoConfig)
                    }
                default:
                    break
                }
            }
            return
        }

        // Тряска: взведённый браслет шлёт 116 со значением 1 на каждый шейк.
        if type == 116 {
            if body.first == 1 { onShake() }
            return
        }

        // Поток DLOG (посекундные пульс+движение) — сырьё для своей разметки
        // сна. Браслет код 6 не шлёт, ночь надо собирать самим из этого потока.
        if type == 250 {
            accumulateDLOG(body)
            return
        }

        let harvest = BraceletProtocol.parse(type: type, body: body)
        guard !harvest.isEmpty else { return }

        sleepMarks.formUnion(harvest.sleepMarks)
        let sleep = BraceletProtocol.segments(from: Array(sleepMarks))

        receivedCount += harvest.heart.count + harvest.oxygen.count
                       + harvest.hrv.count + harvest.temperature.count
                       + harvest.steps.count + harvest.sleepMarks.count
        lastHeard = Date()
        if let fresh = harvest.heart.max(by: { $0.time < $1.time }) {
            lastHeart = fresh.value
        }

        let added = store.absorbHarvest(heart: harvest.heart,
                                        oxygen: harvest.oxygen,
                                        steps: harvest.steps,
                                        sleep: sleep,
                                        hrv: harvest.hrv,
                                        temperature: harvest.temperature)
        // В «Здоровье» отправляем сразу же, не дожидаясь открытия приложения:
        // браслет ничего не хранит, и второго шанса не будет.
        guard added > 0 else { return }

        let nights = store.nights
        Task {
            await HealthService.shared.write(harvest: harvest)
            if !harvest.sleepMarks.isEmpty {
                _ = try? await HealthService.shared.write(nights: nights)
            }
        }
    }
}

extension BraceletCollector: CBCentralManagerDelegate, CBPeripheralDelegate {

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        Task { @MainActor in
            if let peripheral = restored?.first {
                device = peripheral
                peripheral.delegate = self
                state = "восстановлен после перезапуска"
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        Task { @MainActor in
            switch manager.state {
            case .poweredOn: attach(with: manager)
            case .poweredOff: state = "Bluetooth выключен"; isConnected = false
            case .unauthorized: state = "нет разрешения на Bluetooth"
            default: break
            }
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertised ?? ""
        Task { @MainActor in
            guard device == nil, name == deviceName else { return }
            connect(peripheral, with: manager, how: "найден в эфире")
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            isConnected = true
            reassembler = BraceletProtocol.Reassembler()
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ manager: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            isConnected = false
            greeted = false          // при возвращении поздороваемся снова
            writeChar = nil
            outbox = []              // накопленное отправлять поздно
            draining = false
            reassembler = BraceletProtocol.Reassembler()
            journal.add("браслет отключился")
            state = "браслет отключился, жду возвращения"
            // Заявка снова висит бесконечно — iOS подключит, когда он появится.
            manager.connect(peripheral, options: nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverServices error: Error?) {
        Task { @MainActor in
            for service in peripheral.services ?? [] {
                switch service.uuid {
                case Self.service:
                    peripheral.discoverCharacteristics(
                        [Self.notifyChar, Self.writeCharUUID], for: service)
                default:
                    break
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.writeCharUUID { writeChar = characteristic }
                if characteristic.uuid == Self.notifyChar {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
            if service.uuid == Self.service { greet() }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let value = characteristic.value else { return }

        Task { @MainActor in
            for event in reassembler.accept(value) {
                switch event {
                case .message(let type, let seq, let body):
                    // Пишем тело целиком, а не первые байты: на обрезанных
                    // записях уже один раз потерялось содержимое посылок,
                    // которые мы не разбирали.
                    journal.add("← \(type) (\(body.count) б): "
                              + body.prefix(96).map { String(format: "%02x", $0) }.joined())
                    // Подтверждаем сразу и в обход очереди: браслет ждёт ответа
                    // на каждую посылку и без него разрывает связь.
                    acknowledge(type: type, seq: seq)
                    freshSink?(type, body)
                    absorb(type: type, body: body)
                case .started(let type, let pages, let length):
                    journal.add("… начало \(type): \(pages) кусков, \(length) б")
                case .abandoned(let type, let got, let expected):
                    journal.add("⚠️ посылка \(type) оборвана: собрано \(got) из \(expected)")
                case .acknowledged(let type):
                    journal.add("✓ подтверждено \(type)")
                }
            }
        }
    }
}
