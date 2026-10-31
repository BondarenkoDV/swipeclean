import XCTest
@testable import SwipeClean

final class LibraryEditorTests: XCTestCase {
    /// PhotoKit вызывает блок изменений на своей очереди. Если блок привязан к главному актору,
    /// Swift 6 роняет приложение, как это было с «Удалить всё».
    func testDeleteChangesRunOffMainThread() async {
        let changes = await MainActor.run { LibraryEditor.deleteChanges(for: ["missing-id"]) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                changes()
                continuation.resume()
            }
        }
    }
}
