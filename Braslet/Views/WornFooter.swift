import SwiftUI

/// Нижняя полоса на месте убранного трекера тренировок: переключатель
/// «браслет надет / снят». Снят — авто-съём вариабельности и температуры
/// встаёт на паузу, чтобы замеры «на столе» не сбивали личный baseline.
struct WornFooter: View {
    @ObservedObject var collector: BraceletCollector

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { collector.worn.toggle() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: collector.worn ? "applewatch" : "applewatch.slash")
                    .font(.system(size: 17, weight: .semibold))
                Text(collector.worn ? "Браслет надет" : "Снят — эталоны на паузе")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(collector.worn ? "снять" : "надеть")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.tertiarySystemGroupedBackground)))
            }
            .foregroundStyle(collector.worn ? Palette.oxygen : Palette.temperature)
            // Слева больше (под текст), справа — 8, как зазор кнопки сверху/снизу
            // до края блока: так отступы кнопки к блоку совпадают с трёх сторон.
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
    }
}
