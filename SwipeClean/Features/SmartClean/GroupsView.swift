import Photos
import SwiftUI

/// Список групп похожих фото. В каждой группе по умолчанию оставляется лучший кадр, он отмечен «Лучший»,
/// а под группой написано, почему выбран именно он. Если пользователь поменял отметки, снизу появляется кнопка,
/// которая разбирает только изменённые группы.
struct GroupsView: View {
    let title: LocalizedStringKey
    let groups: [AssetGroup]
    let analyzer: SmartCleanAnalyzer

    @Environment(ReviewStore.self) private var store
    @Environment(FullScreenPresenter.self) private var fullScreen
    @Environment(ProtectedStore.self) private var protection
    /// Для каждой группы — фото, которые пользователь решил оставить.
    @State private var kept: [String: Set<String>] = [:]
    @State private var handled: Set<String> = []

    private var visibleGroups: [AssetGroup] {
        groups.filter { !handled.contains($0.id) }
    }

    /// Группы, где отметки пользователя расходятся с предложением приложения.
    private var changedGroups: [AssetGroup] {
        visibleGroups.filter { keptSet($0) != suggested($0) }
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
                    ForEach(displayOrder(group), id: \.localIdentifier) { asset in
                        let isKept = keepSet.contains(asset.localIdentifier)
                        let isProtected = protection.protects(asset)
                        let isBest = asset.localIdentifier == group.bestID
                        AssetThumbnail(asset: asset, side: 110)
                            .frame(width: 110, height: 110)
                            // Превью с заполнением шире рамки, а clipShape обрезает только картинку:
                            // без этого касание у правого края попадало в соседнее фото.
                            .contentShape(Rectangle())
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isKept ? Color.green : Color.red.opacity(0.7), lineWidth: 3))
                            .overlay(alignment: .topLeading) {
                                if isBest {
                                    BestBadge()
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                // Защищённое фото нельзя отметить к удалению: вместо галочки — щит.
                                Image(systemName: isProtected ? "lock.shield.fill" : isKept ? "checkmark.circle.fill" : "trash.circle.fill")
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
                            .accessibilityLabel(isBest ? "Лучший кадр" : "Фото")
                            .accessibilityValue(isProtected ? "Не трогать" : isKept ? "Останется" : "В корзину")
                            .accessibilityAction { toggle(asset, in: group) }
                            .accessibilityAction(named: "Открыть целиком") { fullScreen.asset = asset }
                            .accessibilityIdentifier("groups.photo")
                    }
                }
            }
            if let reason = group.bestReason {
                Label(reason.title, systemImage: reason.symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("groups.bestReason")
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

    private func protectedIDs(in group: AssetGroup) -> Set<String> {
        Set(group.assets.filter { protection.protects($0) }.map(\.localIdentifier))
    }

    /// Что предлагает приложение. Защищённые фото остаются всегда, даже если их защитили уже на этом экране.
    private func suggested(_ group: AssetGroup) -> Set<String> {
        group.keepIDs.union(protectedIDs(in: group))
    }

    /// Лучший кадр первым, остальные в порядке съёмки: в длинной группе он иначе оказывается за краем экрана.
    private func displayOrder(_ group: AssetGroup) -> [PHAsset] {
        guard let best = group.assets.first(where: { $0.localIdentifier == group.bestID }) else { return group.assets }
        return [best] + group.assets.filter { $0.localIdentifier != group.bestID }
    }

    private func keptSet(_ group: AssetGroup) -> Set<String> {
        guard let chosen = kept[group.id] else { return suggested(group) }
        let present = chosen.intersection(group.assets.map(\.localIdentifier))
        // Все фото, которые пользователь оставил, разобрали в другом месте: возвращаемся к предложению,
        // а не удаляем всю группу. Если он сам снял все отметки, это его выбор. Защищённые остаются в любом случае.
        return (present.isEmpty && !chosen.isEmpty ? group.keepIDs : present).union(protectedIDs(in: group))
    }

    private func toggle(_ asset: PHAsset, in group: AssetGroup) {
        guard !protection.protects(asset) else { return }
        var set = keptSet(group)
        let id = asset.localIdentifier
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        // Вернул всё как предлагало приложение: группа больше не считается изменённой.
        kept[group.id] = set == suggested(group) ? nil : set
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
            let keepSet = picks == .mine ? keptSet(group) : suggested(group)
            for asset in group.assets {
                decisions.append(ReviewStore.Decision(asset, keepSet.contains(asset.localIdentifier) ? .keep : .trash))
            }
            handled.insert(group.id)
        }
        store.record(decisions)
        analyzer.removeHandled(Set(decisions.map(\.localIdentifier)))
    }
}

/// Отметка лучшего кадра поверх превью.
private struct BestBadge: View {
    var body: some View {
        Label("Лучший", systemImage: "star.fill")
            .font(.caption2.weight(.bold))
            .labelStyle(BadgeLabelStyle())
            .foregroundStyle(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.yellow, in: Capsule())
            .padding(4)
    }

    /// Звезда и слово вплотную: в превью 110 точек обычный отступ Label слишком велик.
    private struct BadgeLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 2) {
                configuration.icon
                configuration.title
            }
        }
    }
}

extension FaceQuality.Reason {
    /// Подпись под группой: почему этот кадр назван лучшим.
    var title: LocalizedStringKey {
        switch self {
        case .favorite: "Лучший — из избранного"
        case .chosen: "Лучший — вы отметили его в серии"
        case .faces: "Лучший по лицам: открытые глаза и чёткость"
        case .camera: "Лучший — выбор камеры для серии"
        case .sharpness: "Лучший — самый резкий кадр"
        }
    }

    var symbol: String {
        switch self {
        case .favorite: "heart.fill"
        case .chosen: "hand.tap.fill"
        case .faces: "face.smiling"
        case .camera: "camera.fill"
        case .sharpness: "camera.aperture"
        }
    }
}
