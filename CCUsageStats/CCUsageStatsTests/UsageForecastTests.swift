import XCTest
@testable import CCUsageStats

final class UsageForecastTests: XCTestCase {
    func testNotEnoughSamplesYieldsNilSlope() {
        XCTAssertNil(UsageForecast.slope(samples: []))
        XCTAssertNil(UsageForecast.slope(samples: [UsageSample(t: 100, p: 5)]))
    }

    func testFlatTrendYieldsNilSlope() {
        // No change → slope = 0; we treat that as "no useful forecast".
        let s = (0..<5).map { UsageSample(t: 100 + Int64($0) * 60, p: 50) }
        XCTAssertNil(UsageForecast.slope(samples: s))
    }

    func testDecreasingTrendYieldsNilSlope() {
        // Defensive: never project a negative slope toward 100%.
        let s = [
            UsageSample(t: 100, p: 50),
            UsageSample(t: 160, p: 45),
            UsageSample(t: 220, p: 40),
        ]
        XCTAssertNil(UsageForecast.slope(samples: s))
    }

    func testRisingTrendSlopeMatchesArithmetic() {
        // 10% per 60s = ~0.1667% per second. Three points with that rate.
        let s = [
            UsageSample(t: 0,   p: 50),
            UsageSample(t: 60,  p: 60),
            UsageSample(t: 120, p: 70),
        ]
        let slope = UsageForecast.slope(samples: s)!
        XCTAssertEqual(slope, 10.0 / 60.0, accuracy: 1e-6)
    }

    func testSecondsToCapNilWithoutSlope() {
        XCTAssertNil(UsageForecast.secondsToCap(currentPercent: 80, slope: nil))
    }

    func testSecondsToCapNilAtCap() {
        XCTAssertNil(UsageForecast.secondsToCap(currentPercent: 100, slope: 0.5))
    }

    func testSecondsToCapKnownValue() {
        // 0.1% per second from 80% → (100 - 80) / 0.1 = 200 seconds.
        XCTAssertEqual(
            UsageForecast.secondsToCap(currentPercent: 80, slope: 0.1),
            200
        )
    }
}
