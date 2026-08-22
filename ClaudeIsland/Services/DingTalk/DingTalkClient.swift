import CryptoKit
import Foundation

/// Content sent to a DingTalk group robot.
struct DingTalkMessage: Equatable, Sendable {
    let title: String
    let text: String

    /// A privacy-safe message used to verify configuration.
    static let test = DingTalkMessage(
        title: "Vibe Notch - Test",
        text: "DingTalk notifications are configured correctly."
    )
}

/// Sanitized failures produced while sending a DingTalk robot message.
enum DingTalkClientError: Error, Equatable, LocalizedError {
    case missingToken
    case invalidURL
    case transport(code: Int?)
    case invalidResponse
    case httpStatus(Int)
    case invalidPayload
    case business(code: Int, message: String)

    /// A user-facing description that never includes request credentials or content.
    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Robot token is required."
        case .invalidURL:
            return "Could not create the DingTalk request URL."
        case .transport(let code):
            return code.map { "Network request failed (\($0))." } ?? "Network request failed."
        case .invalidResponse:
            return "DingTalk returned an invalid HTTP response."
        case .httpStatus(let statusCode):
            return "DingTalk returned HTTP \(statusCode)."
        case .invalidPayload:
            return "DingTalk returned an unreadable response."
        case .business(let code, let message):
            return "DingTalk error \(code): \(message)"
        }
    }
}

/// Sends Markdown messages to a DingTalk custom group robot.
@MainActor
final class DingTalkClient {
    /// Injectable network transport used by production code and unit tests.
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    private let transport: Transport

    /// Creates a client with an injectable transport.
    init(transport: @escaping Transport = DingTalkClient.liveTransport) {
        self.transport = transport
    }

    /// Sends one message using the supplied credentials and timestamp.
    func send(
        _ message: DingTalkMessage,
        credentials: DingTalkCredentials,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws {
        let request = try makeRequest(
            message: message,
            credentials: credentials.trimmed,
            timestamp: timestamp
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            throw DingTalkClientError.transport(code: error.errorCode)
        } catch {
            throw DingTalkClientError.transport(code: nil)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DingTalkClientError.invalidResponse
        }
        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw DingTalkClientError.httpStatus(httpResponse.statusCode)
        }

        let result: DingTalkAPIResponse
        do {
            result = try JSONDecoder().decode(DingTalkAPIResponse.self, from: data)
        } catch {
            throw DingTalkClientError.invalidPayload
        }

        guard result.errcode == 0 else {
            throw DingTalkClientError.business(code: result.errcode, message: result.errmsg)
        }
    }

    /// Performs a request using the shared system URL session.
    private static func liveTransport(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: request)
    }

    /// Builds a DingTalk Markdown request with optional signing query values.
    private func makeRequest(
        message: DingTalkMessage,
        credentials: DingTalkCredentials,
        timestamp: Int64
    ) throws -> URLRequest {
        guard !credentials.token.isEmpty else {
            throw DingTalkClientError.missingToken
        }

        var components = URLComponents(string: "https://oapi.dingtalk.com/robot/send")
        var queryItems = [URLQueryItem(name: "access_token", value: credentials.token)]

        if !credentials.signingSecret.isEmpty {
            queryItems.append(URLQueryItem(name: "timestamp", value: String(timestamp)))
            queryItems.append(
                URLQueryItem(
                    name: "sign",
                    value: signature(timestamp: timestamp, secret: credentials.signingSecret)
                )
            )
        }

        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw DingTalkClientError.invalidURL
        }

        let payload = DingTalkPayload(
            msgtype: "markdown",
            markdown: DingTalkPayload.Markdown(title: message.title, text: message.text)
        )
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    /// Generates the DingTalk HMAC-SHA256 signature for one timestamp.
    private func signature(timestamp: Int64, secret: String) -> String {
        let input = Data("\(timestamp)\n\(secret)".utf8)
        let key = SymmetricKey(data: Data(secret.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: input, using: key)
        return Data(authenticationCode).base64EncodedString()
    }
}

/// JSON body accepted by the DingTalk robot send endpoint.
private struct DingTalkPayload: Encodable {
    /// Markdown content embedded in the request body.
    struct Markdown: Encodable {
        let title: String
        let text: String
    }

    let msgtype: String
    let markdown: Markdown
}

/// Business response returned by DingTalk.
private struct DingTalkAPIResponse: Decodable {
    let errcode: Int
    let errmsg: String
}
