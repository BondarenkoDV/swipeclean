import Photos
import SwiftUI

/// Список групп похожих фото. В каждой группе по умолчанию оставляется лучший кадр.
/// Если пользователь поменял отметки, снизу появляется кнопка, которая разбирает только изменённые группы.
struct GroupsView: View {
    let title: LocalizedStringKey
    let groups: [AssetGroup]
    let analyzer: SmartCleanAnalyzer

    @Environment(ReviewStore.self) private var store
    @Environment(FullScreenPresenter.self) private var fullScreen
    /// Для каждой группы — фото, которые пользователь решил оставить.
    @State private var kept: [String: Set<String>] = [:]
    @State private var handled: Set<String> = []

    private var visibleGroups: [AssetGroup] {
        groups.filter { !handled.contains($0.id) }
    }

    /// Группы, где отметки пользователя расходятся с предложением приложения.
    private var changedGroups: [AssetGroup] {
        visibleGroups.filter { keptSet($0) != $0.keepIDs }
    }

    var body: some View {
        Group {
            if visibleGroups.isEmpty {
                ContentUnavailableView("Ничего не найдено", systemImage: "checkmark.seal", description: Text("В этой категории не осталось групп."))
            } else {
                List {
                    Section {
                        Button(role: .destructive) {
                            apply(visibleGroups, picks: .suggested)
                        } label: {
                            Label("Оставить лучшие во всех группах", systemImage: "sparkles")
                        }
                        .accessibilityIdentifier("groups.applyAll")
                    } footer: {
                        Text("Нажмите на фото, чтобы поменять отметку: зелёные останутся, красные попадут в корзину приложения. Как только вы что-то поменяете, снизу появится кнопка, которая разберёт только изменённые группы. Удержите фото, чтобы рассмотреть его, а если держать дольше, оно откроется целиком.")
                    }

                    ForEach(visibleGroups) { group in
                        Section {
                            groupRow(group)
                        } header: {
                            if let date = group.assets.first?.creationDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    let changed = changedGroups
                    if !changed.isEmpty {
                        applyChangesButton(changed)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: changedGroups.map(\.id))
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func groupRow(_ group: AssetGroup) -> some View {
        let keepSet = keptSet(group)
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        let isKept = keepSet.contains(asset.localIdentifier)
                        AssetThumbnail(asset: asset, side: 110)
                            .frame(width: 110, height: 110)
                            // Превью с заполнением шире рамки, а clipShape обрезает только картинку:
                            // без этого касание у правого края попадало в соседнее фото.
                            .contentShape(Rectangle())
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isKept ? Color.green : Color.red.opacity(0.7), lineWidth: 3))
                            .overlay(alignment: .topLeading) {
                                if asset.localIdentifier == group.bestID {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .padding(5)
                                        .background(.yellow, in: Circle())
                                        .padding(4)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: isKept ? "checkmark.circle.fill" : "trash.circle.fill")
                                    .font(.title3)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, isKept ? Color.green : Color.red)
                                    .padding(4)
                            }
                            // Тап меняет отметку. Удержание показывает кадр крупно поверх экрана, а если держать
                            // дальше, открывает целиком: похожие кадры иначе не сравнить.
                            .peekAndPop(asset) { toggle(asset, in: group) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel("Фото")
                            .accessibilityValue(isKept ? "Останется" : "В корзину")
                            .accessibilityAction { toggle(asset, in: group) }
                            .accessibilityAction(named: "Открыть целиком") { fullScreen.asset = asset }
                            .accessibilityIdentifier("groups.photo")
                    }
                }
            }
            Button {
                apply([group])
            } label: {
                Text("Оставить \(keepSet.count), удалить \(group.assets.count - keepSet.count)")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(keepSet.count == group.assets.count)
            .accessibilityIdentifier("groups.applyGroup")
        }
        .padding(.vertical, 4)
    }

    /// Плавающая кнопка: разбирает только группы, где пользователь что-то поменял, остальные не трогает.
    private func applyChangesButton(_ changed: [AssetGroup]) -> some View {
        let keep = changed.reduce(0) { $0 + keptSet($1).count }
        let trash = changed.reduce(0) { $0 + $1.assets.count } - keep
        return Button {
            apply(changed)
        } label: {
            VStack(spacing: 2) {
                Text("Применить мой выбор в \(changed.count) группах")
                    .font(.headline)
                Text("Оставить \(keep), удалить \(trash)")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(.horizontal)
        .padding(.bottom, 8)
        .accessibilityIdentifier("groups.applySelection")
    }

    private func keptSet(_ group: AssetGroup) -> Set<String> {
        guard let chosen = kept[group.id] else { return group.keepIDs }
        let present = chosen.intersection(group.assets.map(\.localIdentifier))
        // Все фото, которые пользователь оставил, разобрали в другом месте: возвращаемся к предложению,
        // а не удаляем всю группу. Если он сам снял все отметки, это его выбор.
        return present.isEmpty && !chosen.isEmpty ? group.keepIDs : present
    }

    private func toggle(_ asset: PHAsset, in group: AssetGroup) {
        var set = keptSet(group)
        let id = asset.localIdentifier
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        // Вернул всё как предлагало приложение: группа больше не считается изменённой.
        kept[group.id] = set == group.keepIDs ? nil : set
    }

    /// Какие кадры оставлять при разборе групп.
    private enum Picks {
        /// Отметки пользователя, а в группах, где он ничего не менял, предложение приложения.
        case mine
        /// Только предложение приложения: отметки пользователя не учитываются.
        case suggested
    }

    /// Решения по всем группам записываются одним пакетом: для сотен фото это одно сохранение, а не сотни.
    private func apply(_ groups: [AssetGroup], picks: Picks = .mine) {
        var decisions: [ReviewStore.Decision] = []
        for group in groups {
            let keepSet = picks == .mine ? keptSet(group) : group.keepIDs
            for asset in group.assets {
                decisions.append(ReviewStore.Decision(asset, keepSet.contains(asset.localIdentifier) ? .keep : .trash))
            }
            handled.insert(group.id)
        }
        store.record(decisions)
        analyzer.removeHandled(Set(decisions.map(\.localIdentifier)))
    }
}
