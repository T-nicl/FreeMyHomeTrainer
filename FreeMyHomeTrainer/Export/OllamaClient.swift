import Foundation

/// Valeur JSON quelconque, dans l'ordre d'écriture des clés (schéma envoyé à Ollama).
indirect enum JSONValue: Encodable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([(String, JSONValue)])

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .int(let i): var c = encoder.singleValueContainer(); try c.encode(i)
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .array(let items): var c = encoder.unkeyedContainer(); for item in items { try c.encode(item) }
        case .object(let pairs):
            var c = encoder.container(keyedBy: Key.self)
            for (key, value) in pairs { try c.encode(value, forKey: Key(stringValue: key)) }
        }
    }
}

/// Client de l'API locale d'Ollama (LLM sur le Mac, sans service en ligne).
/// Seules deux routes servent : la liste des modèles installés et la conversation.
struct OllamaClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct Message: Codable, Hashable, Sendable {
        enum Role: String, Codable, Sendable { case system, user, assistant }
        var role: Role
        var content: String
    }

    enum OllamaError: LocalizedError, Equatable {
        case notRunning, timedOut, modelMissing(String), server(String), badResponse

        var errorDescription: String? {
            switch self {
            case .notRunning:
                "Ollama ne répond pas : lance l'app Ollama (ou « brew services start ollama ») puis réessaie."
            case .timedOut:
                "Ollama met trop de temps à répondre. Réessaie, ou choisis un modèle plus léger dans les Réglages."
            case .modelMissing(let model):
                "Le modèle « \(model) » n'est pas installé : lance « ollama pull \(model) » dans le Terminal."
            case .server(let message):
                "Erreur d'Ollama : \(message)"
            case .badResponse:
                "Réponse inattendue : l'adresse indiquée dans les Réglages est-elle bien celle d'Ollama ?"
            }
        }
    }

    static let defaultAddress = "http://localhost:11434"
    static let defaultModel = "qwen2.5:7b"
    /// Génération locale : un modèle de 7 Mds de paramètres met souvent 20 à 60 s (chargement compris).
    static let timeout: TimeInterval = 300
    /// Réponse HTTP plus grosse : refusée (une séance tient en quelques Ko).
    static let maxResponseBytes = 1_000_000
    /// Longueur maximale de la réponse du modèle, en jetons : un modèle qui boucle s'arrête là
    /// (la réponse tronquée est alors refusée puis réparée).
    static let maxReplyTokens = 2_000

    let baseURL: URL
    private let transport: Transport

    init(baseURL: URL, transport: Transport? = nil) {
        self.baseURL = baseURL
        self.transport = transport ?? OllamaClient.download
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()

    /// Téléchargement borné à `maxResponseBytes`.
    @Sendable private static func download(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxResponseBytes { throw OllamaError.badResponse }
        }
        return (data, response)
    }

    /// Les redirections ne sont pas suivies : la demande ne part que vers l'adresse réglée.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Adresse saisie dans les Réglages → URL de base (hôte et port seulement).
    /// « localhost:11434 » est accepté sans « http:// ». HTTP en clair seulement vers le Mac ou
    /// le réseau local ; ailleurs, HTTPS obligatoire (la demande ne doit pas circuler en clair).
    static func baseURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let parsed = URLComponents(string: withScheme),
              let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parsed.host, !host.isEmpty,
              scheme == "https" || isLocal(host) else { return nil }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = parsed.port
        return clean.url
    }

    /// Le Mac lui-même ou le réseau local (noms sans point, .local, adresses privées).
    static func isLocal(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".local") || h == "::1" { return true }
        if h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") { return h.contains(":") }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 1 { return !h.contains(":") }               // nom de machine sans domaine
        let octets = parts.compactMap { UInt8($0) }
        guard parts.count == 4, octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let b): return (16...31).contains(b)
        default: return false
        }
    }

    /// Modèles installés, triés par nom.
    func models() async throws -> [String] {
        struct Tags: Decodable { struct Model: Decodable { var name: String }; var models: [Model] }
        let data = try await send(URLRequest(url: baseURL.appending(path: "api/tags")), model: nil)
        guard let tags = try? JSONDecoder().decode(Tags.self, from: data) else { throw OllamaError.badResponse }
        return tags.models.map(\.name).sorted()
    }

    /// Envoie la conversation et renvoie la réponse du modèle. `format` (schéma JSON) impose
    /// la structure de la réponse (sorties structurées d'Ollama).
    func chat(model: String, messages: [Message], format: JSONValue?) async throws -> String {
        struct Options: Encodable {
            var temperature = 0.3
            var num_ctx = 8192
            var num_predict = OllamaClient.maxReplyTokens
        }
        struct Body: Encodable {
            var model: String
            var messages: [Message]
            var stream = false
            var format: JSONValue?
            var options = Options()
        }
        struct Reply: Decodable { struct Content: Decodable { var content: String }; var message: Content }

        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages, format: format))
        let data = try await send(request, model: model)
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw OllamaError.badResponse }
        return reply.message.content
    }

    private func send(_ request: URLRequest, model: String?) async throws -> Data {
        var request = request
        request.timeoutInterval = Self.timeout
        let data: Data, response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as OllamaError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw OllamaError.timedOut
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet,
                 .dnsLookupFailed, .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection:
                throw OllamaError.notRunning
            default: throw OllamaError.server(error.localizedDescription)
            }
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct Failure: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
            if http.statusCode == 404, let model, message != nil { throw OllamaError.modelMissing(model) }
            guard let message else { throw OllamaError.badResponse }
            throw OllamaError.server(String(message.prefix(300)).replacingOccurrences(of: "\n", with: " "))
        }
        return data
    }
}
