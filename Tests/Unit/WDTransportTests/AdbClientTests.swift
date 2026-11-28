#if os(macOS)
import XCTest
import WDSession
import WDTransport

final class AdbClientTests: XCTestCase {
    func testEncodeRequestUsesFourHexLengthPrefix() {
        let encoded = AdbClient.encodeRequest("host:devices-l")
        XCTAssertEqual(String(bytes: encoded, encoding: .ascii), "000ehost:devices-l")
    }

    func testParseDeviceListFiltersWirelessAndOffline() {
        let output = """
        R52X400123A            device usb:1-1.2 product:gts9wifixx model:SM_X710 device:gts9wifi transport_id:4
        192.168.1.42:5555      device product:panther model:Pixel_7 transport_id:5
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:2
        DEAD1234               offline usb:1-1.3 transport_id:6
        """
        let parsed = AdbClient.parseDeviceList(output)
        XCTAssertEqual(parsed.count, 4)

        let wired = AdbDevice.wiredOnly(parsed)
        XCTAssertEqual(wired.map(\.serial), ["R52X400123A", "emulator-5554"])
        XCTAssertEqual(wired[0].model, "SM X710")
        XCTAssertEqual(wired[0].fleetSerial, "adb:R52X400123A")
        XCTAssertEqual(AdbClient.stripPrefix(wired[0].fleetSerial), "R52X400123A")
        XCTAssertNil(AdbClient.stripPrefix("APPLE-USB-SERIAL-0001"))
    }

    func testCodecSetDecodeLimitFlagsRoundTripInHello() throws {
        let hello = Hello(role: .client, deviceName: "Galaxy Tab S9", pixelWidth: 2560, pixelHeight: 1600,
                          scale: 2, maxRefreshHz: 120, codecs: [.h264, .hevc, .no444, .no10Bit], pixelsPerInch: 274)
        let bytes = SessionCodec.encode(.hello(hello))
        let decoded = try SessionCodec.decodeControl(bytes)
        guard case .hello(let parsed) = decoded else { return XCTFail("expected hello") }
        XCTAssertTrue(parsed.codecs.contains(VideoCodec.h264))
        XCTAssertTrue(parsed.codecs.contains(VideoCodec.hevc))
        XCTAssertTrue(parsed.codecs.contains(.no444))
        XCTAssertTrue(parsed.codecs.contains(.no10Bit))
    }
}
#endif
