import SwiftUI

/// Настройки жеста встряхивания: включение (в т.ч. на срок), действия на
/// одиночную и двойную тряску, список поставленных меток.
struct ShakeSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var collector = BraceletCollector.shared
    @ObservedObject private var store = BrasletStore.shared

    @State private var enabled = ShakeSettings.enabled
    @State private var single = ShakeSettings.singleAction
    @State private var double = ShakeSettings.doubleAction

    /// Отклик на взведение: счётчик для тактильной отдачи и последний
    /// выбранный срок — на нём показываем галочку-подтверждение.
    @State private var armTick = 0
    @State private var armed: ShakeSettings.Duration?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Жест включён", isOn: $enabled)
                    if enabled {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Тряхни браслетом — сработает выбранное действие. Слабую "
                       + "тряску браслет не считает. Во время тренировки жест молчит.")
                }

                if enabled {
                    Section("Взвести на срок") {
                        ForEach(ShakeSettings.Duration.allCases) { duration in
                            Button {
                                ShakeSettings.enable(for: duration)
                                enabled = true
                                armed = duration
                                armTick += 1
                                collector.updateShakeArming()
                            } label: {
                                HStack {
                                    Text(duration.title)
                                    Spacer()
                                    if armed == duration {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Palette.oxygen)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            }
                        }
                    }

                    actionPicker("Одиночная тряска", selection: $single)
                    actionPicker("Двойная тряска", selection: $double)
                }

                if !store.marks.isEmpty {
                    Section {
                        NavigationLink("Метки (\(store.marks.count))") {
                            MarksView()
                        }
                    }
                }
            }
            // Тактильная отдача на каждое взведение — «успех».
            .sensoryFeedback(.success, trigger: armTick)
            .animation(.easeInOut(duration: 0.2), value: armed)
            // Liquid Glass: прячем серый фон формы, под ней — та же абстракция,
            // строки кладём на стекло.
            .scrollContentBackground(.hidden)
            .listRowBackground(glassRow)
            .background(GlassBackdrop())
            .navigationTitle("Жест встряхивания")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .onChange(of: enabled) { _, value in
                ShakeSettings.enabled = value
                collector.updateShakeArming()
            }
            .onChange(of: single) { _, value in ShakeSettings.singleAction = value }
            .onChange(of: double) { _, value in ShakeSettings.doubleAction = value }
        }
    }

    /// Фон строки формы: стекло на iOS 26, иначе прежний сгруппированный фон.
    @ViewBuilder private var glassRow: some View {
        if #available(iOS 26.0, *) {
            Rectangle().fill(.clear).glassEffect(.regular, in: .rect(cornerRadius: 0))
        } else {
            Color(.secondarySystemGroupedBackground)
        }
    }

    private func actionPicker(_ title: String,
                              selection: Binding<ShakeSettings.Action>) -> some View {
        Section(title) {
            Picker(title, selection: selection) {
                ForEach(ShakeSettings.Action.allCases) { action in
                    Label(action.title, systemImage: action.icon).tag(action)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        }
    }

    private var statusText: String {
        guard let until = ShakeSettings.enabledUntil else { return "Взведён постоянно" }
        if until < Date() { return "Срок истёк — выбери новый" }
        return "Взведён до " + until.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Список поставленных меток: время, витальные, ссылка на карту.
private struct MarksView: View {
    @ObservedObject private var store = BrasletStore.shared

    var body: some View {
        List(store.marks) { mark in
            VStack(alignment: .leading, spacing: 4) {
                Text(mark.time.formatted(date: .abbreviated, time: .standard))
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 12) {
                    if let p = mark.pulse { Label("\(p)", systemImage: "heart.fill") }
                    if let o = mark.oxygen { Label("\(o)%", systemImage: "lungs.fill") }
                    if let h = mark.hrv { Label("\(h)", systemImage: "waveform.path.ecg") }
                    if let t = mark.temperature {
                        Label(String(format: "%.1f°", t), systemImage: "thermometer.medium")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if mark.hasLocation, let url = mapURL(mark) {
                    Link("Открыть на карте", destination: url)
                        .font(.caption)
                }
            }
            .padding(.vertical, 2)
        }
        .navigationTitle("Метки")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mapURL(_ mark: Mark) -> URL? {
        guard let lat = mark.latitude, let lon = mark.longitude else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=Метка")
    }
}
