import CoreGraphics
import XCTest
@testable import WDGeometry

final class CoordinateMapperTests: XCTestCase {
    private func assertPoint(_ a: CGPoint?, _ b: CGPoint, accuracy: CGFloat = 0.001,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let a else { return XCTFail("nil point", file: file, line: line) }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testSameAspectMapsAllFourCornersAndCentre() throws {
        // iPad Air 13" view 1366x1024 pt, Mac display 1366x1024 pt at origin.
        let mapper = try XCTUnwrap(CoordinateMapper(viewSize: CGSize(width: 1366, height: 1024),
                                                    displayBounds: CGRect(x: 0, y: 0, width: 1366, height: 1024)))
        XCTAssertEqual(mapper.contentRect, CGRect(x: 0, y: 0, width: 1366, height: 1024))
        assertPoint(mapper.displayPoint(forViewPoint: .zero), CGPoint(x: 0, y: 0))
        assertPoint(mapper.displayPoint(forViewPoint: CGPoint(x: 683, y: 512)), CGPoint(x: 683, y: 512))
        // Far edges clamp just inside the display, never onto a neighbour display.
        let bounds = mapper.displayBounds
        for corner in [CGPoint(x: 1366, y: 0), CGPoint(x: 0, y: 1024), CGPoint(x: 1366, y: 1024)] {
            let mapped = try XCTUnwrap(mapper.displayPoint(forViewPoint: corner))
            XCTAssertTrue(bounds.contains(mapped), "\(mapped) must be inside \(bounds)")
            assertPoint(mapped, corner)
            XCTAssertEqual(Int(mapped.x.rounded(.down)), corner.x == 0 ? 0 : 1365, "last column")
            XCTAssertEqual(Int(mapped.y.rounded(.down)), corner.y == 0 ? 0 : 1023, "last row")
        }
        // Points near the edge are not distorted by the clamp.
        assertPoint(mapper.displayPoint(forViewPoint: CGPoint(x: 1365.9, y: 1023.5)), CGPoint(x: 1365.9, y: 1023.5))
    }

    func testNonMainDisplayOriginIsApplied() throws {
        // Virtual display arranged to the left of and above the main display.
        let bounds = CGRect(x: -1366, y: -200, width: 1366, height: 1024)
        let mapper = try XCTUnwrap(CoordinateMapper(viewSize: CGSize(width: 1366, height: 1024), displayBounds: bounds))
        assertPoint(mapper.displayPoint(forViewPoint: .zero), CGPoint(x: -1366, y: -200))
        let farCorner = try XCTUnwrap(mapper.displayPoint(forViewPoint: CGPoint(x: 1366, y: 1024)))
        XCTAssertTrue(bounds.contains(farCorner))
        assertPoint(farCorner, CGPoint(x: 0, y: 824))
        XCTAssertLessThan(farCorner.x, 0, "must stay on the virtual display, not spill onto the main one")
    }

    func testPillarboxWhenDisplayIsNarrowerThanView() throws {
        // 4:3 display in a 16:9 view: bars left and right.
        let mapper = try XCTUnwrap(CoordinateMapper(viewSize: CGSize(width: 1600, height: 900),
                                                    displayBounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
        XCTAssertEqual(mapper.contentRect, CGRect(x: 200, y: 0, width: 1200, height: 900))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: 199.9, y: 450)), "touch in left bar")
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: 1400.1, y: 450)), "touch in right bar")
        assertPoint(mapper.displayPoint(forViewPoint: CGPoint(x: 200, y: 0)), CGPoint(x: 0, y: 0))
        assertPoint(mapper.displayPoint(forViewPoint: CGPoint(x: 800, y: 450)), CGPoint(x: 400, y: 300))
    }

    func testLetterboxWhenDisplayIsWiderThanView() throws {
        // 16:9 display in a 4:3 view: bars top and bottom.
        let mapper = try XCTUnwrap(CoordinateMapper(viewSize: CGSize(width: 1024, height: 768),
                                                    displayBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080)))
        XCTAssertEqual(mapper.contentRect, CGRect(x: 0, y: 96, width: 1024, height: 576))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: 512, y: 95)))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: 512, y: 673)))
        assertPoint(mapper.displayPoint(forViewPoint: CGPoint(x: 512, y: 384)), CGPoint(x: 960, y: 540))
    }

    func testForwardInverseRoundTripOnGrid() throws {
        let mapper = try XCTUnwrap(CoordinateMapper(viewSize: CGSize(width: 1210, height: 834),
                                                    displayBounds: CGRect(x: 1512, y: -340, width: 1590, height: 1192)))
        for ix in 0...20 {
            for iy in 0...20 {
                let display = CGPoint(x: 1512 + CGFloat(ix) * 1589 / 20, y: -340 + CGFloat(iy) * 1191 / 20)
                let view = try XCTUnwrap(mapper.viewPoint(forDisplayPoint: display))
                XCTAssertTrue(mapper.contentRect.insetBy(dx: -0.001, dy: -0.001).contains(view))
                assertPoint(mapper.displayPoint(forViewPoint: view), display, accuracy: 0.01)
            }
        }
    }

    func testRejectsOutOfRangeAndNonFiniteInput() throws {
        let mapper = try XCTUnwrap(CoordinateMapper(viewSize: CGSize(width: 100, height: 100),
                                                    displayBounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: -0.1, y: 50)))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: 50, y: 100.1)))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: CGFloat.nan, y: 50)))
        XCTAssertNil(mapper.displayPoint(forViewPoint: CGPoint(x: CGFloat.infinity, y: 50)))
        XCTAssertNil(mapper.viewPoint(forDisplayPoint: CGPoint(x: 100, y: 50)), "maxX is outside the display")
        XCTAssertNil(mapper.viewPoint(forDisplayPoint: CGPoint(x: CGFloat.nan, y: 0)))
    }

    func testDegenerateGeometryFailsInit() {
        let ok = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertNil(CoordinateMapper(viewSize: .zero, displayBounds: ok))
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: 10, height: -1), displayBounds: ok))
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: 10, height: 10), displayBounds: .zero))
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: CGFloat.nan, height: 10), displayBounds: ok))
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: 10, height: 10),
                                      displayBounds: CGRect(x: CGFloat.infinity, y: 0, width: 10, height: 10)))
        // Denormal view size: scale underflows to a 0x0 content rect (would map to NaN).
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: CGFloat.leastNonzeroMagnitude, height: 10),
                                      displayBounds: CGRect(x: 0, y: 0, width: 1512, height: 982)))
        // Origin so large that origin + size is not distinguishable or overflows.
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: 10, height: 10),
                                      displayBounds: CGRect(x: CGFloat.greatestFiniteMagnitude, y: 0, width: 10, height: 10)))
        XCTAssertNil(CoordinateMapper(viewSize: CGSize(width: 10, height: 10),
                                      displayBounds: CGRect(x: 1e300, y: 0, width: 10, height: 10)))
    }
}
