import XCTest
@testable import WDUsbmux

final class UsbmuxCodecTests: XCTestCase {
    func testRequestHeaderLayoutAndBodyRoundTrip() throws {
        let packet = try UsbmuxCodec.encodeRequest(["MessageType": "ListDevices"], tag: 0x0A0B_0C0D)
        let header = try UsbmuxCodec.decodeHeader(Array(packet.prefix(16)))
        XCTAssertEqual(Int(header.length), packet.count)
        XCTAssertEqual(header.version, 1)
        XCTAssertEqual(header.type, 8)
        XCTAssertEqual(header.tag, 0x0A0B_0C0D)
        XCTAssertEqual(Array(packet[12..<16]), [0x0D, 0x0C, 0x0B, 0x0A], "little-endian tag")
        let body = try UsbmuxCodec.decodeBody(Array(packet.dropFirst(16)), header: header)
        XCTAssertEqual(body["MessageType"] as? String, "ListDevices")
        XCTAssertEqual(body["ProgName"] as? String, "WiredDisplay")
    }

    func testWirePortIsByteSwapped() {
        XCTAssertEqual(UsbmuxCodec.wirePort(9000), 0x2823) // 9000 = 0x2328
        XCTAssertEqual(UsbmuxCodec.wirePort(0x0102), 0x0201)
        XCTAssertEqual(UsbmuxCodec.wirePort(65535), 65535)
    }

    func testHeaderRejectsTruncatedAndOutOfBoundsLengths() {
        XCTAssertThrowsError(try UsbmuxCodec.decodeHeader([UInt8](repeating: 0, count: 15))) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .truncatedHeader)
        }
        func header(length: UInt32, version: UInt32 = 1, type: UInt32 = 8) -> [UInt8] {
            [length, version, type, 1].flatMap { value in withUnsafeBytes(of: value.littleEndian) { Array($0) } }
        }
        XCTAssertThrowsError(try UsbmuxCodec.decodeHeader(header(length: 15))) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .lengthOutOfBounds(15))
        }
        XCTAssertNoThrow(try UsbmuxCodec.decodeHeader(header(length: 16)))
        XCTAssertNoThrow(try UsbmuxCodec.decodeHeader(header(length: UsbmuxCodec.maxPacketLength)))
        XCTAssertThrowsError(try UsbmuxCodec.decodeHeader(header(length: UsbmuxCodec.maxPacketLength + 1)))
        XCTAssertThrowsError(try UsbmuxCodec.decodeHeader(header(length: .max)))
        XCTAssertThrowsError(try UsbmuxCodec.decodeHeader(header(length: 100, version: 0))) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .unsupportedVersion(0))
        }
        XCTAssertThrowsError(try UsbmuxCodec.decodeHeader(header(length: 100, type: 3))) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .unsupportedType(3))
        }
    }

    func testBodyRejectsLengthMismatchGarbageAndNonDictionary() throws {
        let header = UsbmuxCodec.PacketHeader(length: 16 + 10, version: 1, type: 8, tag: 1)
        XCTAssertThrowsError(try UsbmuxCodec.decodeBody([1, 2, 3], header: header)) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .bodyLengthMismatch(expected: 10, got: 3))
        }
        XCTAssertThrowsError(try UsbmuxCodec.decodeBody([UInt8](repeating: 0xFF, count: 10), header: header))

        let array = try PropertyListSerialization.data(fromPropertyList: ["a", "b"], format: .xml, options: 0)
        let arrayHeader = UsbmuxCodec.PacketHeader(length: UInt32(16 + array.count), version: 1, type: 8, tag: 1)
        XCTAssertThrowsError(try UsbmuxCodec.decodeBody(Array(array), header: arrayHeader)) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .notADictionary)
        }
    }

    func testResultCodes() {
        XCTAssertEqual(UsbmuxResultCode(0), .ok)
        XCTAssertEqual(UsbmuxResultCode(2), .badDevice)
        XCTAssertEqual(UsbmuxResultCode(3), .connectionRefused)
        XCTAssertEqual(UsbmuxResultCode(6), .badVersion)
        XCTAssertEqual(UsbmuxResultCode(99), .unknown(99))
    }

    func testDeviceListParsingAndWiredOnlyFilter() throws {
        let reply: [String: Any] = ["DeviceList": [
            ["DeviceID": 4, "Properties": ["DeviceID": 4, "SerialNumber": "AAAA", "ConnectionType": "USB",
                                           "ConnectionSpeed": 480_000_000, "ProductID": 4779]],
            ["DeviceID": 16, "Properties": ["DeviceID": 16, "SerialNumber": "BBBB", "ConnectionType": "Network"]],
            ["DeviceID": 17, "Properties": ["DeviceID": 17, "SerialNumber": "CCCC", "ConnectionType": "Thread"]],
            ["DeviceID": 18, "Properties": ["SerialNumber": "no id", "ConnectionType": "USB"]], // malformed
            "not a dictionary",
        ]]
        let devices = try UsbmuxDevice.parseList(reply)
        XCTAssertEqual(devices.map(\.deviceID), [4, 16, 17])
        XCTAssertEqual(devices[0].connectionSpeed, 480_000_000)
        XCTAssertEqual(devices[2].connectionType, .other("Thread"))
        // Wired Only must exclude Wi-Fi-synced and unknown transports.
        XCTAssertEqual(UsbmuxDevice.wiredOnly(devices).map(\.serialNumber), ["AAAA"])
    }

    func testDeviceListWithoutListIsAnError() {
        XCTAssertThrowsError(try UsbmuxDevice.parseList(["MessageType": "Result", "Number": 1])) {
            XCTAssertEqual($0 as? UsbmuxCodec.CodecError, .missingField("DeviceList"))
        }
        XCTAssertEqual(try UsbmuxDevice.parseList(["DeviceList": [Any]()]), [])
    }
}
