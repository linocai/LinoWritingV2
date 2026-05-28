import XCTest
@testable import LinoWriting

/// v0.9 §5.W (W-2) — codec round-trips for the device-pairing DTOs and a
/// smoke test that the CoreImage QR generator produces a non-nil image.
final class DevicePairingTests: XCTestCase {

    // MARK: - Model round-trips

    func test_pairInitiateResponse_decoding() throws {
        let json = """
        {"code":"012345","expires_at":"2026-05-28T10:00:00Z"}
        """.data(using: .utf8)!
        let resp = try CodecFactory.makeDecoder().decode(PairInitiateResponse.self, from: json)
        XCTAssertEqual(resp.code, "012345")  // leading zero preserved
    }

    func test_pairConfirmRequest_encodesSnakeCase() throws {
        let req = PairConfirmRequest(code: "123456", deviceName: "linotsai's iPhone")
        let data = try CodecFactory.makeEncoder().encode(req)
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("\"device_name\""))
        XCTAssertFalse(str.contains("\"deviceName\""))
        XCTAssertTrue(str.contains("123456"))
    }

    func test_pairConfirmResponse_decoding() throws {
        let json = """
        {"device_id":"11111111-1111-1111-1111-111111111111","token":"deadbeef"}
        """.data(using: .utf8)!
        let resp = try CodecFactory.makeDecoder().decode(PairConfirmResponse.self, from: json)
        XCTAssertEqual(resp.deviceId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(resp.token, "deadbeef")
    }

    func test_deviceInfo_decoding_nullLastUsed() throws {
        let json = """
        {
          "items": [
            {
              "device_id": "11111111-1111-1111-1111-111111111111",
              "device_name": "MacBook",
              "created_at": "2026-05-28T09:00:00Z",
              "last_used_at": null
            },
            {
              "device_id": "22222222-2222-2222-2222-222222222222",
              "device_name": "iPhone",
              "created_at": "2026-05-28T09:05:00Z",
              "last_used_at": "2026-05-28T09:30:00Z"
            }
          ]
        }
        """.data(using: .utf8)!
        let list = try CodecFactory.makeDecoder().decode(ListResponse<DeviceInfo>.self, from: json)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertNil(list.items[0].lastUsedAt)
        XCTAssertNotNil(list.items[1].lastUsedAt)
        // Identifiable id maps to device_id.
        XCTAssertEqual(list.items[0].id, "11111111-1111-1111-1111-111111111111")
    }

    func test_pairingPayload_base64_roundTrip_withIP() throws {
        let payload = PairingPayload(
            url: "https://lw.linotsai.top",
            code: "654321",
            ipOverride: "118.178.122.194"
        )
        let base64 = try XCTUnwrap(payload.base64Encoded())
        let decoded = try XCTUnwrap(PairingPayload.fromBase64(base64))
        XCTAssertEqual(decoded.url, payload.url)
        XCTAssertEqual(decoded.code, payload.code)
        XCTAssertEqual(decoded.ipOverride, "118.178.122.194")
    }

    func test_pairingPayload_omitsIP_whenNil() throws {
        let payload = PairingPayload(url: "https://x", code: "111111", ipOverride: nil)
        let data = try JSONEncoder().encode(payload)
        let str = String(data: data, encoding: .utf8)!
        // Compact keys per §5.W.2; `ip` omitted entirely when unknown.
        XCTAssertTrue(str.contains("\"u\""))
        XCTAssertTrue(str.contains("\"c\""))
        XCTAssertFalse(str.contains("\"ip\""))
        // And it still round-trips with nil.
        let decoded = try XCTUnwrap(PairingPayload.fromBase64(payload.base64Encoded()!))
        XCTAssertNil(decoded.ipOverride)
    }

    func test_pairingPayload_fromBase64_rejectsGarbage() {
        XCTAssertNil(PairingPayload.fromBase64("not base64 !!!"))
        // Valid base64 but not our JSON shape.
        let junk = Data("{\"foo\":1}".utf8).base64EncodedString()
        XCTAssertNil(PairingPayload.fromBase64(junk))
    }

    // MARK: - QR generation

    func test_qrCodeGenerator_producesImage() {
        let cg = QRCodeGenerator.makeCGImage(from: "https://lw.linotsai.top|123456")
        XCTAssertNotNil(cg)
        XCTAssertGreaterThan(cg?.width ?? 0, 0)
        #if os(macOS)
        let ns = QRCodeGenerator.makeNSImage(from: "hello")
        XCTAssertNotNil(ns)
        #endif
    }
}
