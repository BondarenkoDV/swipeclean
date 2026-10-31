import XCTest
@testable import SwipeClean

final class MetricsCacheTests: XCTestCase {
    /// Каждый запуск умной чистки начинает с чистого листа: метрики прошлого запуска не используются.
    func testFreshLoadDropsPreviousRun() {
        let cache = MetricsCache.load()
        cache["metrics-cache-test"] = MetricsCache.Entry(sharpness: 1, hash: 42)
        cache.saveIfNeeded()
        XCTAssertNotNil(MetricsCache.load()["metrics-cache-test"], "Обычная загрузка видит сохранённое")

        XCTAssertNil(MetricsCache.load(fresh: true)["metrics-cache-test"], "Новый запуск не видит прошлых метрик")
        XCTAssertNil(MetricsCache.load()["metrics-cache-test"], "После нового запуска старых записей на диске нет")
    }
}
