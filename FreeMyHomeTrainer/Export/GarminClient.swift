import CryptoKit
import Foundation

/// Envoi vers Garmin Connect — NON OFFICIEL.
/// Garmin ne propose pas d'API publique aux particuliers : on reproduit la connexion SSO
/// de l'app mobile Garmin Connect (même méthode que la librairie open source « garth »).
/// La connexion se fait sur la page Garmin elle-même (GarminLoginSheet) : l'app ne voit
/// jamais le mot de passe et ne garde que les jetons, dans le Trousseau.
/// Ce module peut cesser de fonctionner si Garmin modifie sa connexion.
@MainActor
final class GarminClient {
    private struct OAuth1Token: Codable {
        var token: String
        var secret: String
        var mfaToken: String?
    }

    private struct OAuth2Token: Codable {
        var accessToken: String
        var expiresAt: Date
    }

    private struct Consumer: Decodable {
        var consumer_key: String
        var consumer_secret: String
    }

    enum GarminError: LocalizedError {
        case unexpectedResponse(String), notConnected

        var errorDescription: String? {
            switch self {
            case .unexpectedResponse(let p): "Réponse inattendue de Garmin (\(p)). La connexion Garmin a peut-être changé."
            case .notConnected: "Compte Garmin non connecté."
            }
        }
    }

    nonisolated static let sso = "https://sso.garmin.com/sso"
    private static let connectAPI = "https://connectapi.garmin.com"
    private static let userAgent = "com.garmin.android.apps.connectmobile"
    private let oauth1Account = "garmin.oauth1"
    private let oauth2Account = "garmin.oauth2"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": GarminClient.userAgent]
        return URLSession(configuration: config)
    }()
    private var consumer: Consumer?

    private var oauth1: OAuth1Token? {
        get { Keychain.get(OAuth1Token.self, for: oauth1Account) }
        set { Keychain.set(newValue, for: oauth1Account) }
    }

    private var oauth2: OAuth2Token? {
        get { Keychain.get(OAuth2Token.self, for: oauth2Account) }
        set { Keychain.set(newValue, for: oauth2Account) }
    }

    var isConnected: Bool { oauth1 != nil }

    func disconnect() {
        oauth1 = nil
        oauth2 = nil
    }

    /// Page de connexion Garmin (widget SSO). Une fois connecté, Garmin redirige vers
    /// `…/sso/embed?ticket=ST-…` : ce ticket est échangé contre les jetons.
    nonisolated static var loginURL: URL {
        let params = [
            "id": "gauth-widget",
            "embedWidget": "true",
            "gauthHost": "\(sso)/embed",
            "service": "\(sso)/embed",
            "source": "\(sso)/embed",
            "redirectAfterAccountLoginUrl": "\(sso)/embed",
            "redirectAfterAccountCreationUrl": "\(sso)/embed",
        ]
        return URL(string: "\(sso)/signin?\(FormEncoding.encode(params))")!
    }

    /// Extrait le ticket SSO d'une URL de redirection ou d'une page HTML.
    nonisolated static func ticket(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"ticket=(ST-[A-Za-z0-9\-._]+)"#),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    // MARK: - Jetons OAuth

    private func loadConsumer() async throws -> Consumer {
        if let consumer { return consumer }
        let url = URL(string: "https://thegarth.s3.amazonaws.com/oauth_consumer.json")!
        let (data, response) = try await URLSession.shared.data(from: url)
        try HTTPError.check(response, data)
        let c = try JSONDecoder().decode(Consumer.self, from: data)
        consumer = c
        return c
    }

    /// Ticket SSO → jeton OAuth 1 (longue durée) → jeton OAuth 2 (accès API).
    func connect(ticket: String) async throws {
        let consumer = try await loadConsumer()
        let query = ["ticket": ticket, "login-url": "\(Self.sso)/embed", "accepts-mfa-tokens": "true"]
        let base = "\(Self.connectAPI)/oauth-service/oauth/preauthorized"
        var request = URLRequest(url: URL(string: "\(base)?\(FormEncoding.encode(query))")!)
        request.setValue(OAuth1.header(method: "GET", url: base, params: query,
                                       consumerKey: consumer.consumer_key, consumerSecret: consumer.consumer_secret),
                         forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try HTTPError.check(response, data)
        let fields = FormEncoding.decode(String(decoding: data, as: UTF8.self))
        guard let token = fields["oauth_token"], let secret = fields["oauth_token_secret"] else {
            throw GarminError.unexpectedResponse("jeton OAuth1 absent")
        }
        oauth1 = OAuth1Token(token: token, secret: secret, mfaToken: fields["mfa_token"])
        try await refreshOAuth2()
    }

    private func refreshOAuth2() async throws {
        guard let o1 = oauth1 else { throw GarminError.notConnected }
        let consumer = try await loadConsumer()
        let url = "\(Self.connectAPI)/oauth-service/oauth/exchange/user/2.0"
        var form: [String: String] = [:]
        if let mfa = o1.mfaToken, !mfa.isEmpty { form["mfa_token"] = mfa }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(OAuth1.header(method: "POST", url: url, params: form,
                                       consumerKey: consumer.consumer_key, consumerSecret: consumer.consumer_secret,
                                       token: o1.token, tokenSecret: o1.secret),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = Data(FormEncoding.encode(form).utf8)
        let (data, response) = try await session.data(for: request)
        try HTTPError.check(response, data)

        struct Response: Decodable { var access_token: String; var expires_in: TimeInterval }
        let r = try JSONDecoder().decode(Response.self, from: data)
        oauth2 = OAuth2Token(accessToken: r.access_token, expiresAt: Date().addingTimeInterval(r.expires_in))
    }

    private func validAccessToken() async throws -> String {
        if let o2 = oauth2, o2.expiresAt.timeIntervalSinceNow > 120 { return o2.accessToken }
        try await refreshOAuth2()
        guard let o2 = oauth2 else { throw GarminError.notConnected }
        return o2.accessToken
    }

    // MARK: - Envoi

    /// Envoie un .FIT sur Garmin Connect. Un doublon (409) est considéré comme un succès.
    func upload(fit: Data, fileName: String) async throws {
        let token = try await validAccessToken()
        var body = MultipartBody()
        body.addFile("file", fileName: fileName, mimeType: "application/octet-stream", content: fit)
        var request = URLRequest(url: URL(string: "\(Self.connectAPI)/upload-service/upload")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finalized()
        let (data, response) = try await session.data(for: request)
        try HTTPError.check(response, data, accept: Set(200..<300).union([409]))
    }
}

/// Signature OAuth 1.0a (HMAC-SHA1).
enum OAuth1 {
    static func header(method: String, url: String, params: [String: String],
                       consumerKey: String, consumerSecret: String,
                       token: String? = nil, tokenSecret: String? = nil,
                       nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                       timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        var oauth: [String: String] = [
            "oauth_consumer_key": consumerKey,
            "oauth_nonce": nonce,
            "oauth_signature_method": "HMAC-SHA1",
            "oauth_timestamp": String(timestamp),
            "oauth_version": "1.0",
        ]
        if let token { oauth["oauth_token"] = token }

        let all = params.merging(oauth) { $1 }
        let paramString = all.map { (FormEncoding.percentEncode($0.key), FormEncoding.percentEncode($0.value)) }
            .sorted { $0 < $1 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")
        let baseString = [method.uppercased(), FormEncoding.percentEncode(url), FormEncoding.percentEncode(paramString)]
            .joined(separator: "&")
        let key = "\(FormEncoding.percentEncode(consumerSecret))&\(FormEncoding.percentEncode(tokenSecret ?? ""))"
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(baseString.utf8), using: SymmetricKey(data: Data(key.utf8)))
        oauth["oauth_signature"] = Data(mac).base64EncodedString()

        return "OAuth " + oauth.sorted { $0.key < $1.key }
            .map { "\($0.key)=\"\(FormEncoding.percentEncode($0.value))\"" }
            .joined(separator: ", ")
    }
}
