import Foundation
import Security

enum ConnectionError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum TokenStore {
    private static let service = "com.caligab.fitfind.local-service"
    static func read() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "access-token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "access-token"]
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw ConnectionError.message("Could not securely save the connection token.")
            }
        } else if status != errSecSuccess {
            throw ConnectionError.message("Could not securely save the connection token.")
        }
    }
}

struct RecognitionClient {
    let endpoint: String
    let token: String

    private func request(path: String) throws -> URLRequest {
        guard let url = URL(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.query == nil,
              url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw ConnectionError.message("Enter a server address such as http://your-mac.local:8787 in Settings.")
        }
        let local = host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".local")
        guard url.scheme == "https" || (url.scheme == "http" && local) else {
            throw ConnectionError.message("Use HTTPS, or your Mac's .local address for local testing.")
        }
        guard token.count >= 24 else {
            throw ConnectionError.message("Add the local service access token in Settings first.")
        }
        var request = URLRequest(url: url.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 55
        return request
    }

    func checkConnection() async throws -> String {
        let request = try request(path: "health")
        let data = try await send(request)
        struct Health: Decodable { let ready: Bool }
        let health = try JSONDecoder().decode(Health.self, from: data)
        return health.ready ? "Connected. Recognition is ready." : "Connected. Add GEMINI_API_KEY on your Mac to enable recognition."
    }

    func analyze(image: Data, context: String) async throws -> Analysis {
        var request = try request(path: "analyze")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Payload: Encodable { let imageBase64: String; let context: String }
        request.httpBody = try JSONEncoder().encode(Payload(imageBase64: image.base64EncodedString(), context: context))
        let data = try await send(request)
        do { return try JSONDecoder().decode(Analysis.self, from: data).validated() }
        catch { throw AnalysisError.invalidResponse }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnalysisError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw ConnectionError.message(failure?.error ?? "The recognition service could not complete the request.")
        }
        return data
    }
}
