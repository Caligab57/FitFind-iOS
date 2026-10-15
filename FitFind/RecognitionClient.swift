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
        struct Health: Decodable {
            let ready: Bool
            let recognitionConfigured: Bool?
            let shoppingConfigured: Bool?
        }
        let health = try JSONDecoder().decode(Health.self, from: data)
        let recognition = health.recognitionConfigured ?? health.ready
        let shopping = health.shoppingConfigured ?? false
        return "Connected. Recognition: \(recognition ? "configured" : "add GEMINI_API_KEY on your server"). " +
            "Product search: \(shopping ? "configured" : "add SERPAPI_API_KEY on your server"). " +
            "Configuration checked only; live results have not been verified."
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

    func findProducts(analysis: Analysis, budgetCents: Int?) async throws -> ProductSearchResponse {
        _ = try analysis.validated()
        guard !analysis.garments.isEmpty,
              budgetCents.map({ (100...1_000_000).contains($0) }) ?? true else {
            throw ConnectionError.message("Choose a valid budget and analyze an outfit before searching.")
        }
        var request = try request(path: "products")
        request.httpMethod = "POST"
        request.timeoutInterval = 55
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Payload: Encodable {
            let analysis: Analysis
            let budgetCents: Int?
            enum CodingKeys: String, CodingKey { case analysis, budgetCents, currency }
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(analysis, forKey: .analysis)
                try container.encode(budgetCents, forKey: .budgetCents)
                try container.encode("USD", forKey: .currency)
            }
        }
        request.httpBody = try JSONEncoder().encode(Payload(analysis: analysis, budgetCents: budgetCents))
        let data = try await send(request)
        do {
            return try JSONDecoder().decode(ProductSearchResponse.self, from: data)
                .validated(for: analysis, budgetCents: budgetCents)
        } catch { throw ProductSearchError.invalidResponse }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RejectServiceRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnalysisError.invalidResponse }
        guard !(300...399).contains(http.statusCode) else {
            throw ConnectionError.message("The service tried to redirect the request. The redirect was blocked; enter the service's direct address in Settings.")
        }
        guard (200...299).contains(http.statusCode) else {
            struct Failure: Decodable { let error: String }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            throw ConnectionError.message(failure?.error ?? "The FitFind service could not complete the request.")
        }
        return data
    }
}


// Redirects are unnecessary for this API and must never forward photos or access tokens.
private final class RejectServiceRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
