import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct PairingRelayClient: Sendable {
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
        let initiator_device_id: String
        let initiator_device_name: String
        let initiator_public_key: String
    }

    private struct CreatePairingCodeResponse: Decodable {
        let code: String
        let expires_at: Date
    }

    private struct ChallengePollQuery: Encodable {
        let initiator_device_id: String
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String
    }

    private struct SubmitAckRequest: Encodable {
        let initiator_device_id: String
        let ack: String
    }

    private struct AckPollQuery: Encodable {
        let responder_device_id: String
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
        initiatorDeviceId: UUID,
        initiatorDeviceName: String,
        initiatorPublicKey: Data
    ) async throws -> PairingCode {
        let requestBody = CreatePairingCodeRequest(
            initiator_device_id: initiatorDeviceId.uuidString,
            initiator_device_name: initiatorDeviceName,
            initiator_public_key: initiatorPublicKey.base64EncodedString()
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

    public func pollChallenge(code: String, initiatorDeviceId: UUID) async throws -> String {
        let queryParams = ChallengePollQuery(initiator_device_id: initiatorDeviceId.uuidString)
        let query = URLQueryItem(name: "initiator_device_id", value: queryParams.initiator_device_id)
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

    public func submitAck(code: String, initiatorDeviceId: UUID, ackJSON: String) async throws {
        let request = SubmitAckRequest(initiator_device_id: initiatorDeviceId.uuidString, ack: ackJSON)
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

    public func pollAck(code: String, responderDeviceId: String) async throws -> String {
        let queryParams = AckPollQuery(responder_device_id: responderDeviceId)
        let query = URLQueryItem(name: "responder_device_id", value: queryParams.responder_device_id)
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
