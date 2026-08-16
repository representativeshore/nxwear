import SwiftUI

extension Color {
    /// Цвет, который сам меняется вместе с темой оформления.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red:   CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue:  CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

extension SleepStage {
    /// Цвета проверены на различимость при дальтонизме и на контраст с фоном —
    /// отдельно для светлой и тёмной темы, а не инверсией одной из другой.
    /// Порядок подобран под стопку: холодные тона на сон, тёплый на пробуждения.
    var color: Color {
        switch self {
        case .deep:  return .adaptive(light: 0x2A78D6, dark: 0x3987E5)  // синий
        case .core:  return .adaptive(light: 0x1BAF7A, dark: 0x199E70)  // аквамарин
        case .rem:   return .adaptive(light: 0x4A3AA7, dark: 0x9085E9)  // фиолетовый
        case .awake: return .adaptive(light: 0xEB6834, dark: 0xD95926)  // оранжевый
        case .inBed: return Color.secondary.opacity(0.4)
        }
    }
}

enum Palette {
    /// Один ряд данных — один тон, без пестроты.
    static let steps = Color.adaptive(light: 0x2A78D6, dark: 0x3987E5)
    static let heart = Color.adaptive(light: 0xE34948, dark: 0xE66767)
    static let oxygen = Color.adaptive(light: 0x1BAF7A, dark: 0x199E70)
    static let temperature = Color.adaptive(light: 0xD1730B, dark: 0xE08A1E)
    static let hrv = Color.adaptive(light: 0xB0399C, dark: 0xC55BB2)

    /// Ненавязчивая сетка — она фон, а не содержание.
    static let grid = Color.secondary.opacity(0.18)
}

extension View {
    /// Карточка на сгруппированном фоне.
    func cardStyle() -> some View {
        self
            .padding(18)
            .glassCard(cornerRadius: 20)
    }

    /// Фон карточки: Liquid Glass на iOS 26, иначе — прежняя сплошная заливка.
    /// Таргет проекта — iOS 17, поэтому стекло под проверкой доступности.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground)))
        }
    }
}

/// Группирует несколько стеклянных элементов, чтобы они сэмплировали фон
/// согласованно и красиво перетекали. На iOS < 26 — прозрачная обёртка.
@ViewBuilder
func GlassGroup<Content: View>(spacing: CGFloat = 8,
                               @ViewBuilder content: () -> Content) -> some View {
    if #available(iOS 26.0, *) {
        GlassEffectContainer(spacing: spacing) { content() }
    } else {
        content()
    }
}
