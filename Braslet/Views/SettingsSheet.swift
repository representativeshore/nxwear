import SwiftUI

/// Панель настроек, выпадающая вниз прямо из шестерёнки (popover), а не
/// нижний лист — палец уже наверху у шестерёнки, туда же и раскрывается.
/// Карточки в стиле «Настроек» iOS: иконки в цветных квадратах, тумблеры и
/// строки-переходы.
struct SettingsSheet: View {
    @ObservedObject var collector: BraceletCollector

    @AppStorage("braslet.wristRaise") private var wristRaise = true
    @AppStorage("braslet.callAlerts") private var callAlerts = true

    @State private var showsShake = false
    @State private var showsCamera = false

    var body: some View {
        VStack(spacing: 14) {
            Text("Настройки")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            card {
                toggleRow("rotate.3d", Palette.hrv, "Экран по повороту", $wristRaise)
                rowDivider
                toggleRow("phone.fill", Palette.oxygen, "Оповещать о звонке", $callAlerts)
            }

            card {
                navRow("hand.wave.fill", Palette.temperature,
                       "Жест встряхивания", "действия по тряске браслета") {
                    showsShake = true
                }
                rowDivider
                navRow("camera.fill", Palette.steps,
                       "Камера-затвор", "снимок по кнопке браслета") {
                    showsCamera = true
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .glassCard(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Обводка по периметру — иначе поповер сливается с карточками экрана.
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1))
        .sheet(isPresented: $showsShake) { ShakeSettingsView() }
        .fullScreenCover(isPresented: $showsCamera) { ShutterCamera() }
        .onChange(of: wristRaise) { _, on in collector.setWristRaise(on) }
        .onChange(of: callAlerts) { _, on in collector.setCallAlerts(on) }
    }

    // MARK: - Строительные блоки

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .glassCard(cornerRadius: 16)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 58)
    }

    private func icon(_ name: String, _ tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint)
            .frame(width: 29, height: 29)
            .overlay(
                Image(systemName: name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white))
    }

    private func toggleRow(_ name: String, _ tint: Color,
                           _ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            icon(name, tint)
            Text(title)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func navRow(_ name: String, _ tint: Color, _ title: String,
                        _ subtitle: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon(name, tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
