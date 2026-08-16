import AVFoundation
import CoreLocation
import UIKit

// Действия жеста встряхивания. Каждое самодостаточно и вызывается сборщиком.

// MARK: - Маячок «найти телефон»

/// Громкий звук (поверх беззвучного), мигание фонарика и экрана. Останавливается
/// сам через время или повторным вызовом.
@MainActor
final class PhoneFinder: NSObject {
    static let shared = PhoneFinder()

    private var player: AVAudioPlayer?
    private var torchTimer: Timer?
    private var torchOn = false
    private var flashWindow: UIWindow?
    private var stopWork: DispatchWorkItem?
    private(set) var isRunning = false

    func toggle() { isRunning ? stop() : start() }

    func start(seconds: TimeInterval = 20) {
        guard !isRunning else { return }
        isRunning = true

        // playback перебивает беззвучный переключатель — маячок должен звучать.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: Self.beep())
        player?.numberOfLoops = -1
        player?.volume = 1
        player?.play()

        torchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.blink() }
        }
        showFlashWindow()

        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func stop() {
        isRunning = false
        player?.stop(); player = nil
        torchTimer?.invalidate(); torchTimer = nil
        setTorch(false)
        flashWindow?.isHidden = true; flashWindow = nil
        stopWork?.cancel(); stopWork = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func blink() {
        torchOn.toggle()
        setTorch(torchOn)
        flashWindow?.backgroundColor = torchOn ? .white : .black
    }

    private func setTorch(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch,
              (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
    }

    /// Белое окно поверх всего — мигает вместе с фонариком. Работает только
    /// когда телефон разблокирован и экран доступен.
    private func showFlashWindow() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .black
        window.isUserInteractionEnabled = false
        window.isHidden = false
        flashWindow = window
    }

    /// Двухтональный писк в WAV, в памяти. Резкий, чтобы цеплять слух.
    private static func beep() -> Data {
        let rate = 16000.0, seconds = 0.9
        let count = Int(rate * seconds)
        var samples = [Int16]()
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / rate
            // Чередуем два тона по четвертям секунды.
            let freq = (Int(t * 4) % 2 == 0) ? 880.0 : 1320.0
            let value = sin(2 * .pi * freq * t)
            samples.append(Int16(value * 28000))
        }
        return wav(samples: samples, rate: Int(rate))
    }

    private static func wav(samples: [Int16], rate: Int) -> Data {
        var data = Data()
        let byteRate = rate * 2, dataSize = samples.count * 2
        func put(_ s: String) { data.append(contentsOf: s.utf8) }
        func put32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func put16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        put("RIFF"); put32(36 + dataSize); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1); put32(rate); put32(byteRate); put16(2); put16(16)
        put("data"); put32(dataSize)
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        return data
    }
}

// MARK: - Диктофон

/// Запись звука. Первый вызов — старт, второй — стоп. Файл ложится в папку
/// приложения, доступную через «Файлы». В фоне работает благодаря режиму audio.
@MainActor
final class Dictaphone {
    static let shared = Dictaphone()

    private var recorder: AVAudioRecorder?
    private(set) var isRecording = false

    func toggle() { isRecording ? stop() : start() }

    private func start() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("запись-\(stamp).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
        ]
        recorder = try? AVAudioRecorder(url: url, settings: settings)
        recorder?.record()
        isRecording = recorder != nil
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}

// MARK: - Геолокация для метки

/// Разовый запрос текущего места — для метки события. Переиспользует
/// разрешение локации, что уже дано для маршрута тренировки.
@MainActor
final class MarkLocator: NSObject, CLLocationManagerDelegate {
    static let shared = MarkLocator()

    private let manager = CLLocationManager()
    // Очередь, а не одно замыкание: две тряски подряд при холодном GPS раньше
    // затирали completion предыдущей — первая метка молча терялась.
    private var pending: [(CLLocation?) -> Void] = []

    override init() {
        super.init()
        manager.delegate = self
    }

    func fetch(_ done: @escaping (CLLocation?) -> Void) {
        pending.append(done)
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.requestLocation()
    }

    private func deliver(_ location: CLLocation?) {
        let waiting = pending
        pending = []
        waiting.forEach { $0(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.deliver(locations.last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in self.deliver(nil) }
    }
}
