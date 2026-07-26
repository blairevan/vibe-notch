import Foundation
import XCTest
@testable import Vibe_Notch

/// Verifies DingTalk request construction and response handling.
@MainActor
final class DingTalkClientTests: XCTestCase {
    /// Verifies an unsigned request includes the encoded robot token and Markdown payload.
    func testUnsignedRequestUsesTokenAndMarkdownBody() async throws {
        let recorder = RequestRecorder(responseBody: #"{"errcode":0,"errmsg":"ok"}"#)
        let client = DingTalkClient(transport: recorder.send)

        try await client.send(
            DingTalkMessage(title: "Vibe Notch - Test", text: "hello"),
            credentials: DingTalkCredentials(token: "token value", signingSecret: ""),
            timestamp: 1_700_000_000_000
        )

        let request = try XCTUnwrap(recorder.request)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "oapi.dingtalk.com")
        XCTAssertEqual(queryValue(named: "access_token", in: components), "token value")
        XCTAssertNil(queryValue(named: "timestamp", in: components))
        XCTAssertNil(queryValue(named: "sign", in: components))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 10)

        let payload = try JSONDecoder().decode(TestPayload.self, from: try XCTUnwrap(request.httpBody))
        XCTAssertEqual(payload.msgtype, "markdown")
        XCTAssertEqual(payload.markdown.title, "Vibe Notch - Test")
        XCTAssertEqual(payload.markdown.text, "hello")
    }

    /// Verifies a signing secret adds the documented timestamp and HMAC signature.
    func testSignedRequestUsesExpectedSignature() async throws {
        let recorder = RequestRecorder(responseBody: #"{"errcode":0,"errmsg":"ok"}"#)
        let client = DingTalkClient(transport: recorder.send)

        try await client.send(
            .test,
            credentials: DingTalkCredentials(token: "token", signingSecret: "secret"),
            timestamp: 1_700_000_000_000
        )

        let request = try XCTUnwrap(recorder.request)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(queryValue(named: "timestamp", in: components), "1700000000000")
        XCTAssertEqual(queryValue(named: "sign", in: components), "OuzzJR5+xZ4/EYwqtNt6sMYZQMTa/HEGvc9miJe7XzY=")
    }

    /// Verifies an empty token is rejected before transport is called.
    func testMissingTokenIsRejected() async {
        let recorder = RequestRecorder(responseBody: #"{"errcode":0,"errmsg":"ok"}"#)
        let client = DingTalkClient(transport: recorder.send)

        await assertThrows(.missingToken) {
            try await client.send(.test, credentials: .empty)
        }
        XCTAssertNil(recorder.request)
    }

    /// Verifies a non-success HTTP response becomes a typed error.
    func testHTTPFailureThrowsStatusError() async {
        let recorder = RequestRecorder(statusCode: 503, responseBody: "unavailable")
        let client = DingTalkClient(transport: recorder.send)

        await assertThrows(.httpStatus(503)) {
            try await client.send(.test, credentials: DingTalkCredentials(token: "token", signingSecret: ""))
        }
    }

    /// Verifies DingTalk business failures preserve only the public error details.
    func testBusinessFailureThrowsTypedError() async {
        let recorder = RequestRecorder(responseBody: #"{"errcode":310000,"errmsg":"invalid token"}"#)
        let client = DingTalkClient(transport: recorder.send)

        await assertThrows(.business(code: 310000, message: "invalid token")) {
            try await client.send(.test, credentials: DingTalkCredentials(token: "secret-token", signingSecret: ""))
        }
    }

    /// Verifies malformed response data is reported without exposing the request.
    func testMalformedResponseThrowsInvalidPayload() async {
        let recorder = RequestRecorder(responseBody: "not-json")
        let client = DingTalkClient(transport: recorder.send)

        await assertThrows(.invalidPayload) {
            try await client.send(.test, credentials: DingTalkCredentials(token: "token", signingSecret: ""))
        }
    }

    /// Returns a decoded query value by name.
    private func queryValue(named name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }

    /// Asserts an asynchronous operation throws the expected client error.
    private func assertThrows(
        _ expected: DingTalkClientError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected DingTalkClientError")
        } catch let error as DingTalkClientError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }
}

/// Captures requests while returning a deterministic HTTP response.
@MainActor
private final class RequestRecorder {
    private(set) var request: URLRequest?
    private let statusCode: Int
    private let responseData: Data

    /// Creates a recorder with a chosen response.
    init(statusCode: Int = 200, responseBody: String) {
        self.statusCode = statusCode
        self.responseData = Data(responseBody.utf8)
    }

    /// Records one request and returns the configured response.
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        self.request = request
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://oapi.dingtalk.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }
}

/// Decodes the request body used in client assertions.
private struct TestPayload: Decodable {
    /// Decodes Markdown fields used by DingTalk.
    struct Markdown: Decodable {
        let title: String
        let text: String
    }

    let msgtype: String
    let markdown: Markdown
}
