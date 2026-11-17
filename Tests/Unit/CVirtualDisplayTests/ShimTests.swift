#if os(macOS)
import CVirtualDisplay
import CoreGraphics
import XCTest

/// None of these tests creates a display: invalid configs are rejected before
/// any private object is built, and the ownership check builds only the
/// descriptor/mode/settings objects, which do not talk to WindowServer.
final class ShimTests: XCTestCase {
    private func onlineDisplayCount() -> UInt32 {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        return count
    }

    func testAvailabilityCheckMatchesRecordedABIOnThisOS() throws {
        if let error = WDVirtualDisplayCheckAvailability() {
            throw XCTSkip("private surface differs on this OS (fail-closed path): \(error.localizedDescription)")
        }
    }

    func testSupportObjectsAreDeallocatedWhenDropped() throws {
        guard WDVirtualDisplayCheckAvailability() == nil else { throw XCTSkip("private surface unavailable") }
        XCTAssertTrue(WDVirtualDisplayDebugSupportObjectsAreReleased(), "BUG-004: private objects leaked")
    }

    func testInvalidConfigsAreRejectedWithoutCreatingADisplay() throws {
        guard WDVirtualDisplayCheckAvailability() == nil else { throw XCTSkip("private surface unavailable") }
        let before = onlineDisplayCount()
        func config(_ mutate: (WDVirtualDisplayConfig) -> Void) -> WDVirtualDisplayConfig {
            let c = WDVirtualDisplayConfig()
            c.pixelsWide = 2732; c.pixelsHigh = 2048
            c.sizeInMillimeters = CGSize(width: 262.9, height: 197.1)
            mutate(c)
            return c
        }
        let invalid: [WDVirtualDisplayConfig] = [
            config { $0.pixelsWide = 0 },
            config { $0.pixelsWide = 2733 },              // odd width cannot be @2x
            config { $0.pixelsHigh = 8194 },              // above cap
            config { $0.pixelsHigh = 100 },               // below floor
            config { $0.sizeInMillimeters = .zero },
            config { $0.sizeInMillimeters = CGSize(width: CGFloat.nan, height: 10) },
            config { $0.refreshRate = 0 },
            config { $0.refreshRate = 500 },
            config { $0.refreshRate = .infinity },
            config { $0.name = "" },
        ]
        for (index, bad) in invalid.enumerated() {
            XCTAssertThrowsError(try WDVirtualDisplayHandle.create(with: bad), "config #\(index)") { error in
                let nsError = error as NSError
                XCTAssertEqual(nsError.domain, WDVirtualDisplayErrorDomain)
                XCTAssertEqual(nsError.code, WDVirtualDisplayError.invalidArgument.rawValue)
            }
        }
        XCTAssertEqual(onlineDisplayCount(), before, "a rejected config must not add a display")
    }
}
#endif
