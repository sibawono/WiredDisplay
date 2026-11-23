import Foundation
import XCTest
@testable import WDUsbmux

final class LockdownTests: XCTestCase {
    func testRequestIsBigEndianLengthPlusXMLPlist() throws {
        let bytes = try Lockdown.encode(["Request": "GetValue", "Key": "DeviceName"])
        let length = Lockdown.bodyLength(Array(bytes.prefix(4)))
        XCTAssertEqual(length, bytes.count - 4)
        let plist = try PropertyListSerialization.propertyList(from: Data(bytes.dropFirst(4)), format: nil) as? [String: String]
        XCTAssertEqual(plist, ["Request": "GetValue", "Key": "DeviceName"])
        XCTAssertTrue(String(decoding: bytes.dropFirst(4), as: UTF8.self).hasPrefix("<?xml"))
    }

    func testBodyLengthRejectsZeroOversizeAndShortHeaders() {
        XCTAssertNil(Lockdown.bodyLength([0, 0, 0, 0]))
        XCTAssertNil(Lockdown.bodyLength([0, 0x20, 0, 1]), "over 1 MB")
        XCTAssertNil(Lockdown.bodyLength([0, 1]))
        XCTAssertEqual(Lockdown.bodyLength([0, 0, 1, 2]), 258)
    }

    func testStringValueReadsValueAndIgnoresErrors() throws {
        let ok = try PropertyListSerialization.data(fromPropertyList: ["Key": "DeviceName", "Value": "Alex’s iPad"],
                                                   format: .xml, options: 0)
        XCTAssertEqual(Lockdown.stringValue(Array(ok)), "Alex’s iPad")
        let error = try PropertyListSerialization.data(fromPropertyList: ["Error": "GetProhibited"], format: .xml, options: 0)
        XCTAssertNil(Lockdown.stringValue(Array(error)))
        XCTAssertNil(Lockdown.stringValue(Array("not a plist".utf8)))
    }

    func testModelNames() {
        XCTAssertEqual(DeviceIdentity(productType: "iPad14,10").modelName, "iPad Air 13-inch (M2)")
        XCTAssertEqual(DeviceIdentity(productType: "iPad16,6").modelName, "iPad Pro 13-inch (M4)")
        XCTAssertEqual(DeviceIdentity(productType: "iPad99,1").modelName, "iPad99,1", "unknown model shows its identifier")
        XCTAssertEqual(DeviceIdentity(deviceClass: "iPad").modelName, "iPad")
        XCTAssertNil(DeviceIdentity().modelName)
    }
}
