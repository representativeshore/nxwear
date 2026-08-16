import CallKit
import Foundation

/// Фейковый входящий через CallKit — системный экран звонка. В отличие от
/// своего экрана, всплывает даже когда приложение закрыто и телефон
/// заблокирован (для этого объявлен фоновый режим `voip`). Через 20 секунд
/// сам «сбрасывается».
@MainActor
final class FakeCall: NSObject, CXProviderDelegate {
    static let shared = FakeCall()

    /// Имя, которое CallKit показывает строкой «… аудиовызов». По умолчанию
    /// пусто, чтобы не светить «Браслет». Задаём через localizedName провайдера
    /// — это отдельно от имени приложения, переименовывать апп не нужно.
    private static let providerName = " "

    private let provider: CXProvider = {
        let config = CXProviderConfiguration(localizedName: providerName)
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        return CXProvider(configuration: config)
    }()

    override init() {
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func ring(caller: String = "Лёха (ФСБ)") {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.hasVideo = false
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.provider.reportCall(with: uuid, endedAt: nil, reason: .remoteEnded)
        }
    }

    // Ответил или сбросил — просто закрываем, звонок фейковый.
    nonisolated func providerDidReset(_ provider: CXProvider) {}
    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
    }
    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        action.fulfill()
    }
}
