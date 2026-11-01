import XCTest
@testable import SwipeClean

final class ProtectionTests: XCTestCase {
    private typealias Plan = AssetGroup.ProtectionPlan

    func testPolicyProtectsListedAndOptionallyFavorites() {
        let listed = ProtectionPolicy(ids: ["a"], includesFavorites: false)
        XCTAssertTrue(listed.protects(id: "a", isFavorite: false))
        XCTAssertFalse(listed.protects(id: "b", isFavorite: true))

        let withFavorites = ProtectionPolicy(ids: ["a"], includesFavorites: true)
        XCTAssertTrue(withFavorites.protects(id: "b", isFavorite: true))
        XCTAssertFalse(withFavorites.protects(id: "c", isFavorite: false))

        XCTAssertTrue(ProtectionPolicy.nothing.isEmpty)
        XCTAssertFalse(ProtectionPolicy(includesFavorites: true).isEmpty)
    }

    /// Точные копии: защищённая копия остаётся вместо той, что выбрало приложение, остальные уходят.
    func testExactCopiesKeepProtectedCopyInsteadOfBest() {
        let plan = AssetGroup.protectionPlan(
            ids: ["best", "copy", "mine"], bestID: "best", keepIDs: ["best"], protected: ["mine"], replacesBest: true
        )
        XCTAssertEqual(plan, Plan(bestID: "mine", keepIDs: ["mine"]))
    }

    /// Похожие кадры: лучший кадр — другой снимок, он остаётся вместе с защищённым.
    func testSimilarKeepsBestAlongsideProtected() {
        let plan = AssetGroup.protectionPlan(
            ids: ["best", "other", "mine"], bestID: "best", keepIDs: ["best"], protected: ["mine"], replacesBest: false
        )
        XCTAssertEqual(plan, Plan(bestID: "best", keepIDs: ["best", "mine"]))
    }

    /// Если защищён сам лучший кадр, группа не меняется.
    func testProtectedBestChangesNothing() {
        let plan = AssetGroup.protectionPlan(
            ids: ["best", "copy"], bestID: "best", keepIDs: ["best"], protected: ["best"], replacesBest: true
        )
        XCTAssertEqual(plan, Plan(bestID: "best", keepIDs: ["best"]))
    }

    /// Нечего удалять — группа больше не показывается.
    func testGroupWithNothingToDeleteIsDropped() {
        XCTAssertNil(AssetGroup.protectionPlan(
            ids: ["best", "mine"], bestID: "best", keepIDs: ["best"], protected: ["mine"], replacesBest: false
        ))
        XCTAssertNil(AssetGroup.protectionPlan(
            ids: ["a", "b"], bestID: "a", keepIDs: ["a"], protected: ["a", "b"], replacesBest: true
        ))
    }

    /// Кадры серии, которые пользователь отметил сам, остаются, даже когда защищённый кадр становится главным.
    func testUserPicksStayWhenBestIsReplaced() {
        let plan = AssetGroup.protectionPlan(
            ids: ["pick1", "pick2", "mine", "rest"], bestID: "pick1", keepIDs: ["pick1", "pick2"], protected: ["mine"], replacesBest: true
        )
        XCTAssertEqual(plan, Plan(bestID: "mine", keepIDs: ["pick1", "pick2", "mine"]))
    }

    func testNoProtectedLeavesGroupAsIs() {
        let plan = AssetGroup.protectionPlan(
            ids: ["a", "b"], bestID: "a", keepIDs: ["a"], protected: [], replacesBest: true
        )
        XCTAssertEqual(plan, Plan(bestID: "a", keepIDs: ["a"]))
    }

    // MARK: - Хранилище

    @MainActor
    func testStorePersistsListAndFavoritesSwitch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "ProtectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProtectedStore(uiTesting: false, fileURL: url, defaults: defaults, publishesPolicy: false)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.protectsFavorites, "Избранное должно быть защищено по умолчанию")
        store.add(["a", "b", "a"])
        store.remove(["b"])
        store.setProtectsFavorites(false)
        XCTAssertEqual(store.policy, ProtectionPolicy(ids: ["a"], includesFavorites: false))

        let reopened = ProtectedStore(uiTesting: false, fileURL: url, defaults: defaults, publishesPolicy: false)
        XCTAssertEqual(reopened.ids, ["a"])
        XCTAssertFalse(reopened.protectsFavorites)
    }

    @MainActor
    func testUITestingStoreStartsEmptyAndWritesNothing() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "ProtectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ProtectedStore(uiTesting: true, fileURL: url, defaults: defaults, publishesPolicy: false)
        store.add(["a"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testPublishedPolicyIsVisibleToBackgroundCode() async {
        let previous = ProtectionPolicy.current
        defer { ProtectionPolicy.publish(previous) }
        let policy = ProtectionPolicy(ids: ["x"], includesFavorites: false)
        ProtectionPolicy.publish(policy)
        let seen = await Task.detached { ProtectionPolicy.current }.value
        XCTAssertEqual(seen, policy)
    }
}
