import SwiftUI

/// Живой абстрактный фон под стеклянными карточками. Не битмап, а
/// `MeshGradient` (iOS 18+) с цветными «кляксами» в тёмных тонах — стекло
/// подхватывает их и заметно играет бликами. Тона адаптивны к теме: тёмные
/// в ночной, светлые в дневной, чтобы текст оставался читаемым.
struct GlassBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.55, 0.45], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: colors)
            } else {
                LinearGradient(colors: [colors[0], colors[4], colors[8]],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
    }

    private var colors: [Color] {
        (scheme == .dark ? dark : light).map { Color(UIColor(rgb: $0)) }
    }

    // Тёмные навигационно-синие, фиолетовые и бирюзовые пятна — глубокие, но
    // не чёрные, чтобы у стекла было что отражать.
    private let dark: [UInt32] = [
        0x141B2A, 0x0F1420, 0x1D1533,
        0x0E2436, 0x1A2138, 0x281B3C,
        0x0F2C2B, 0x14213E, 0x201634
    ]

    private let light: [UInt32] = [
        0xEAF0F8, 0xEEEAF6, 0xE6EEF5,
        0xDCE8F5, 0xF1EEF8, 0xE2ECF3,
        0xEBF2F7, 0xE7EAF6, 0xF2EEF7
    ]
}
