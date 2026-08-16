import SwiftUI

/// Один экран без прокрутки: сверху сон, снизу показатели, внизу тренировка.
/// Вглубь листается вбок — так на маленьком экране помещается больше,
/// чем в бесконечной ленте карточек.
struct ContentView: View {
    @ObservedObject private var store = BrasletStore.shared
    @ObservedObject private var collector = BraceletCollector.shared

    @State private var showsLog = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Шапка и футер занимают ровно свой рост, зазор между сном и
        // карточками — фиксированный, а сами сон и карточки делят остаток
        // ГИБКО (maxHeight: .infinity). Так они не могут вырасти за отведённое
        // и налезть друг на друга — что бы я ни менял в отступах шапки.
        VStack(spacing: 0) {
            SyncHeader(collector: collector,
                       lastSync: store.lastSync,
                       battery: store.battery,
                       lastHeard: collector.lastHeard)
                .padding(.horizontal, 6)
                .padding(.bottom, 16)   // воздух между шапкой и блоком сна
                // Долгое нажатие на шапку открывает журнал. Он нужен
                // для разбора неполадок, а не каждый день, поэтому
                // спрятан и ничем себя не выдаёт.
                .contentShape(.rect)
                .onLongPressGesture { showsLog = true }

            SleepPages(nights: store.nights)
                .frame(maxHeight: .infinity)

            Color.clear.frame(height: 8)   // явный зазор сон ↔ карточки

            MetricPages(store: store, collector: collector)
                .frame(maxHeight: .infinity)

            WornFooter(collector: collector)
                .frame(height: 54)
                .padding(.top, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(GlassBackdrop())
        .task { store.importFromDocuments() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { collector.refreshWorn() }
        }
        .sheet(isPresented: $showsLog) { LogView() }
    }
}

#Preview {
    ContentView()
}
