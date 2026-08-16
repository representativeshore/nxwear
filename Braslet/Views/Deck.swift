import SwiftUI

/// Колода страниц, листаемая вбок.
///
/// Намеренно без кольца: и клоны со скачком, и длинная лента из повторов
/// выглядели хуже простого края — на стыке был заметен рывок. Три страницы,
/// начало и конец, ничего не перескакивает.
///
/// Все карточки одного размера: уменьшать соседние — значит показывать
/// одни и те же данные в разном масштабе, а это сбивает. Единственный эффект
/// при листании — лёгкое притухание уходящей страницы.
struct Deck<Item: Identifiable & Equatable, Page: View>: View {
    let items: [Item]
    @ViewBuilder let page: (Item) -> Page

    var body: some View {
        ScrollView(.horizontal) {
            // Зазор между страницами делаем отступом внутри страницы,
            // а не расстоянием в ленте: иначе каждая следующая страница
            // смещается на его величину и карточки перестают совпадать.
            LazyHStack(spacing: 0) {
                ForEach(items) { item in
                    page(item)
                        .padding(.horizontal, 3)
                        .containerRelativeFrame(.horizontal)
                        .scrollTransition(.interactive, axis: .horizontal) { view, phase in
                            view.opacity(phase.isIdentity ? 1 : 0.7)
                        }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
    }
}
