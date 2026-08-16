import SwiftUI

/// Журнал обмена с браслетом. Новое сверху.
struct LogView: View {
    @ObservedObject private var journal = Journal.shared
    @ObservedObject private var collector = BraceletCollector.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showsProfile = false

    var body: some View {
        NavigationStack {
            Group {
                if journal.lines.isEmpty {
                    Text("Пока пусто")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(journal.lines.reversed()) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(Fmt.time(line.at))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                    Text(line.text)
                                        .font(.caption)
                                        .textSelection(.enabled)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Журнал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = journal.plainText
                        } label: {
                            Label("Скопировать всё", systemImage: "doc.on.doc")
                        }
                        Button {
                            collector.probeCapabilities()
                        } label: {
                            Label("Опросить возможности", systemImage: "questionmark.circle")
                        }
                        Button {
                            collector.probeSensors()
                        } label: {
                            Label("Проверить датчики", systemImage: "sensor")
                        }
                        Button {
                            showsProfile = true
                        } label: {
                            Label("Профиль (тех.)", systemImage: "person.text.rectangle")
                        }
                        Button(role: .destructive) {
                            journal.clear()
                        } label: {
                            Label("Очистить", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showsProfile) { ProfileEditor() }
        }
    }
}

/// Техническое поле веса и процента жира — только для расчётов (сухая масса,
/// VO2max). Владелец мерит биоимпедансом раз в пару недель, оба значения
/// плавают. Спрятано в три точки лога, на основной экран не выводится.
private struct ProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var weight = String(format: "%.0f", Profile.weightKg)
    @State private var bodyFat = String(format: "%.0f", Profile.bodyFatPercent)

    var body: some View {
        NavigationStack {
            Form {
                Section("Замер биоимпеданса") {
                    LabeledContent("Вес, кг") {
                        TextField("99", text: $weight)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Жир, %") {
                        TextField("15", text: $bodyFat)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Text("Только для расчётов сухой массы и VO2max. Нигде не выводится.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") { save(); dismiss() }
                }
            }
        }
    }

    private func save() {
        if let w = Double(weight.replacingOccurrences(of: ",", with: ".")),
           (30...300).contains(w) {
            Profile.weightKg = w
        }
        if let f = Double(bodyFat.replacingOccurrences(of: ",", with: ".")),
           (3...60).contains(f) {
            Profile.bodyFatPercent = f
        }
    }
}
