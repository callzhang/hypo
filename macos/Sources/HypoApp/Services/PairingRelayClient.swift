import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PairingRelayClient {
    public struct PairingCode: Equatable {
        public let code: String
        public let expiresAt: Date
    }

    public enum Error: Swift.Error, LocalizedError {
        case invalidResponse
        case server(String)
        case codeExpired
        case challengeNotReady
        case ackNotReady

        public var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "Invalid response from relay"
            case .server(let message):
                return message
            case .codeExpired:
                return "Pairing code expired"
            case .challengeNotReady:
                return "Challenge not yet available"
            case .ackNotReady:
                return "Acknowledgement not yet available"
            }
        }
    }

    private struct CreatePairingCodeRequest: Encodable {
        let mac_device_id: String
        let mac_device_name: String
        let mac_public_key: String
    }

    private struct CreatePairingCodeResponse: Decodable {
        let code: String
        let expires_at: Date
    }

    private struct ChallengePollQuery: Encodable {
        let mac_device_id: String
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private struct SubmitAckRequest: Encodable {
        let mac_device_id: String
        let ack: String
    }

    private struct AckPollQuery: Encodable {
        let android_device_id: String
    }

    private struct AckResponse: Decodable {
        let ack: String
    }

    private struct ErrorEnvelope: Decodable {
        let error: String
    }

    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        var sanitized = baseURL
        if baseURL.pathComponents.last == "ws" {
            sanitized = baseURL.deletingLastPathComponent()
        }
        if sanitized.pathComponents.count > 1, sanitized.path == "/" {
            sanitized = sanitized.deletingLastPathComponent()
        }
        self.baseURL = sanitized
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func createPairingCode(
        macDeviceId: UUID,
        macDeviceName: String,
        macPublicKey: Data
    ) async throws -> PairingCode {
        let requestBody = CreatePairingCodeRequest(
            mac_device_id: macDeviceId.uuidString,
            mac_device_name: macDeviceName,
            mac_public_key: macPublicKey.base64EncodedString()
        )
        let (data, response) = try await send(
            path: "/pairing/code",
            method: "POST",
            body: try encoder.encode(requestBody)
        )
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        if http.statusCode == 200 {
            let payload = try decoder.decode(CreatePairingCodeResponse.self, from: data)
            return PairingCode(code: payload.code, expiresAt: payload.expires_at)
        }
        throw try parseError(data: data, response: http)
    }

    public func pollChallenge(code: String, macDeviceId: UUID) async throws -> String {
        let query = URLQueryItem(name: "mac_device_id", value: macDeviceId.uuidString)
        let (data, response) = try await send(
            path: "/pairing/code/\(code)/challenge",
            method: "GET",
            queryItems: [query]
        )
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        if http.statusCode == 200 {
            let payload = try decoder.decode(ChallengeResponse.self, from: data)
            return payload.challenge
        }
        throw try parseError(data: data, response: http)
    }

    public func submitAck(code: String, macDeviceId: UUID, ackJSON: String) async throws {
        let request = SubmitAckRequest(mac_device_id: macDeviceId.uuidString, ack: ackJSON)
        let (data, response) = try await send(
            path: "/pairing/code/\(code)/ack",
            method: "POST",
            body: try encoder.encode(request)
        )
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return
        }
        throw try parseError(data: data, response: http)
    }

    public func pollAck(code: String, androidDeviceId: String) async throws -> String {
        let query = URLQueryItem(name: "android_device_id", value: androidDeviceId)
        let (data, response) = try await send(
            path: "/pairing/code/\(code)/ack",
            method: "GET",
            queryItems: [query]
        )
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        if http.statusCode == 200 {
            let payload = try decoder.decode(AckResponse.self, from: data)
            return payload.ack
        }
        throw try parseError(data: data, response: http)
    }

    private func send(
        path: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        body: Data? = nil
    ) async throws -> (Data, URLResponse) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw Error.invalidResponse
        }
        var cleanPath = components.path
        if !cleanPath.hasSuffix("/") {
            cleanPath += "/"
        }
        components.path = cleanPath + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let queryItems {
            components.queryItems = queryItems
        }
        guard let url = components.url else { throw Error.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await session.data(for: request)
    }

    private func parseError(data: Data, response: HTTPURLResponse) throws -> Error {
        if response.statusCode == 410 {
            return .codeExpired
        }
        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data) {
            switch envelope.error.lowercased() {
            case let message where message.contains("challenge not available"):
                return .challengeNotReady
            case let message where message.contains("acknowledgement not available"):
                return .ackNotReady
            default:
                return .server(envelope.error)
            }
        }
        if (400..<600).contains(response.statusCode) {
            return .server("Relay error (status \(response.statusCode))")
        }
        return .invalidResponse
    }
}
