import XCTest
@testable import SwipeClean

final class VaultTests: XCTestCase {
    func testPasscodeHashIsStableAndDistinct() {
        XCTAssertEqual(VaultKeychain.hash("1234"), VaultKeychain.hash("1234"))
        XCTAssertNotEqual(VaultKeychain.hash("1234"), VaultKeychain.hash("1235"))
    }

    @MainActor
    func testPasscodeUnlocksOnlyWithRightCode() {
        let vault = VaultStore(uiTesting: true)
        XCTAssertFalse(vault.hasPasscode)
        vault.setPasscode("2580")
        XCTAssertTrue(vault.isUnlocked)
        vault.lock()
        XCTAssertFalse(vault.isUnlocked)
        XCTAssertFalse(vault.unlock(with: "0000"))
        XCTAssertTrue(vault.unlock(with: "2580"))
        vault.erase()
        XCTAssertFalse(vault.hasPasscode)
    }

    func testLockoutGrowsAfterFreeAttempts() {
        XCTAssertNil(VaultStore.lockout(afterFailures: VaultStore.freeAttempts - 1))
        XCTAssertEqual(VaultStore.lockout(afterFailures: VaultStore.freeAttempts), 30)
        XCTAssertEqual(VaultStore.lockout(afterFailures: VaultStore.freeAttempts + 1), 60)
        XCTAssertEqual(VaultStore.lockout(afterFailures: VaultStore.freeAttempts + 20), 3600)
    }

    @MainActor
    func testWrongCodesPauseEvenTheRightCode() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "VaultTests.lockout"))
        defaults.removePersistentDomain(forName: "VaultTests.lockout")
        let vault = VaultStore(uiTesting: true, defaults: defaults)
        vault.setPasscode("2580")
        vault.lock()
        let start = Date(timeIntervalSince1970: 1_000_000)
        for _ in 0..<VaultStore.freeAttempts {
            XCTAssertFalse(vault.unlock(with: "0000", now: start))
        }
        XCTAssertEqual(vault.lockedUntil, start.addingTimeInterval(30))
        XCTAssertFalse(vault.unlock(with: "2580", now: start.addingTimeInterval(29)))

        // Пауза переживает перезапуск приложения.
        let reopened = VaultStore(uiTesting: false, defaults: defaults)
        XCTAssertEqual(reopened.lockedUntil, start.addingTimeInterval(30))

        XCTAssertTrue(vault.unlock(with: "2580", now: start.addingTimeInterval(31)))
        XCTAssertNil(vault.lockedUntil)
        XCTAssertNil(defaults.object(forKey: SettingsKeys.vaultLockedUntil))
        vault.erase()
        defaults.removePersistentDomain(forName: "VaultTests.lockout")
    }

    func testDeviceStorageIsConsistent() throws {
        let storage = try XCTUnwrap(DeviceStorage.current())
        XCTAssertGreaterThan(storage.total, 0)
        XCTAssertLessThanOrEqual(storage.available, storage.total)
        XCTAssertEqual(storage.used, storage.total - storage.available)
    }
}
