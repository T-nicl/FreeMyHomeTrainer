import Foundation

/// Client de l'API Strava officielle : OAuth et envoi de fichiers .FIT.
/// Nécessite une application créée sur https://www.strava.com/settings/api
/// avec « localhost » comme Authorization Callback Domain.
@MainActor
final class StravaClient {
    struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var athleteName: String?
    }

    enum StravaError: LocalizedError {
        case missingCredentials, notConnected, authorizationDenied, uploadFailed(String), uploadTimeout

        var errorDescription: String? {
            switch self {
            case .missingCredentials: "Clés de l'application Strava absentes (voir le README)."
            case .notConnected: "Compte Strava non connecté."
            case .authorizationDenied: "Autorisation Strava refusée."
            case .uploadFailed(let m): "Strava a refusé le fichier : \(m)"
            case .uploadTimeout: "Strava n'a pas fini de traiter le fichier à temps. Vérifie sur strava.com."
            }
        }
    }

    static let callbackScheme = "freemyhometrainer"
    static let redirectURI = "freemyhometrainer://localhost/strava"

    private let secretAccount = "strava.clientSecret"
    private let tokensAccount = "strava.tokens"

    /// Clés intégrées à la compilation (Config/Local.xcconfig → Info.plist).
    private static func bundled(_ key: String) -> String? {
        let value = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?.trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
    }

    var hasBundledCredentials: Bool {
        Self.bundled("StravaClientID") != nil && Self.bundled("StravaClientSecret") != nil
    }

    var hasCredentials: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    /// Clés de l'application Strava : intégrées à l'app, sinon saisies dans les Réglages.
    var clientID: String {
        get { Self.bundled("StravaClientID") ?? UserDefaults.standard.string(forKey: Settings.stravaClientIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: Settings.stravaClientIDKey) }
    }

    var clientSecret: String {
        get { Self.bundled("StravaClientSecret") ?? Keychain.get(String.self, for: secretAccount) ?? "" }
        set { Keychain.set(newValue.trimmingCharacters(in: .whitespaces), for: secretAccount) }
    }

    private(set) var tokens: Tokens? {
        get { Keychain.get(Tokens.self, for: tokensAccount) }
        set { Keychain.set(newValue, for: tokensAccount) }
    }

    var isConnected: Bool { tokens != nil }
    var athleteName: String? { tokens?.athleteName }

    func disconnect() { tokens = nil }

    func authorizationURL() throws -> URL {
        guard hasCredentials else { throw StravaError.missingCredentials }
        var c = URLComponents(string: "https://www.strava.com/oauth/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "approval_prompt", value: "auto"),
            .init(name: "scope", value: "activity:write,read"),
        ]
        return c.url!
    }

    /// Termine l'OAuth à partir de l'URL de retour (freemyhometrainer://localhost/strava?code=…).
    func completeAuthorization(callback: URL) async throws {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw StravaError.authorizationDenied
        }
        tokens = try await requestToken(["grant_type": "authorization_code", "code": code])
    }

    private func requestToken(_ params: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://www.strava.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["client_id"] = clientID
        all["client_secret"] = clientSecret
        request.httpBody = Data(FormEncoding.encode(all).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPError.check(response, data)

        struct Response: Decodable {
            struct Athlete: Decodable { var firstname: String?; var lastname: String? }
            var access_token: String
            var refresh_token: String
            var expires_at: TimeInterval
            var athlete: Athlete?
        }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let name = [r.athlete?.firstname, r.athlete?.lastname].compactMap { $0 }.joined(separator: " ")
        return Tokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                      expiresAt: Date(timeIntervalSince1970: r.expires_at),
                      athleteName: name.isEmpty ? tokens?.athleteName : name)
    }

    private func validAccessToken() async throws -> String {
        guard let current = tokens else { throw StravaError.notConnected }
        if current.expiresAt.timeIntervalSinceNow > 120 { return current.accessToken }
        let refreshed = try await requestToken(["grant_type": "refresh_token", "refresh_token": current.refreshToken])
        tokens = refreshed
        return refreshed.accessToken
    }

    /// Envoie un .FIT et attend que Strava ait créé l'activité. Renvoie l'id de l'activité.
    func upload(fit: Data, name: String, externalID: String) async throws -> Int {
        let token = try await validAccessToken()
        var body = MultipartBody()
        body.addField("data_type", "fit")
        body.addField("name", name)
        body.addField("trainer", "1")
        body.addField("external_id", externalID)
        body.addFile("file", fileName: "\(externalID).fit", mimeType: "application/octet-stream", content: fit)

        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finalized()

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTPError.check(response, data)
        var status = try JSONDecoder().decode(UploadStatusResponse.self, from: data)

        // Strava traite le fichier de façon asynchrone : on interroge le statut.
        for _ in 0..<30 {
            if let error = status.error, !error.isEmpty { throw StravaError.uploadFailed(error) }
            if let activityID = status.activity_id { return activityID }
            try await Task.sleep(for: .seconds(2))
            var poll = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(status.id)")!)
            poll.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: poll)
            try HTTPError.check(response, data)
            status = try JSONDecoder().decode(UploadStatusResponse.self, from: data)
        }
        throw StravaError.uploadTimeout
    }

    private struct UploadStatusResponse: Decodable {
        var id: Int
        var status: String?
        var error: String?
        var activity_id: Int?
    }
}

enum FormEncoding {
    /// Encodage RFC 3986 (caractères non réservés uniquement), utilisé aussi pour OAuth 1.
    static func percentEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    static func encode(_ params: [String: String]) -> String {
        params.sorted { $0.key < $1.key }
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
    }

    static func decode(_ string: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in string.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            out[key] = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
        }
        return out
    }
}
