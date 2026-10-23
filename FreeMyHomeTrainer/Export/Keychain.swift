import Foundation
import Security

/// Stockage des secrets (jetons Garmin) dans le Trousseau.
enum Keychain {
    private static let service = "fr.timothenicole.FreeMyHomeTrainer"

    /// Écrit (ou efface, si `value` est nil) une valeur. Renvoie false si le Trousseau refuse.
    /// Remarque : l'app utilise le Trousseau « fichier » de macOS, protégé par la liste d'accès de
    /// l'app ; les attributs d'accessibilité (`kSecAttrAccessible…`) n'y ont pas d'effet.
    @discardableResult
    static func set<T: Encodable>(_ value: T?, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard let value else {
            let deleted = SecItemDelete(query as CFDictionary)
            return deleted == errSecSuccess || deleted == errSecItemNotFound
        }
        guard let data = try? JSONEncoder().encode(value) else { return false }
        // Mise à jour d'abord : en cas d'échec, l'ancienne valeur n'est pas perdue.
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get<T: Decodable>(_ type: T.Type, for account: String) -> T? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

/// Corps multipart/form-data pour les envois de fichiers.
struct MultipartBody {
    let boundary = "Boundary-\(UUID().uuidString)"
    private(set) var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, mimeType: String, content: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(Self.headerSafe(name))\"; filename=\"\(Self.headerSafe(fileName))\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(content)
        data.append(Data("\r\n".utf8))
    }

    func finalized() -> Data { data + Data("--\(boundary)--\r\n".utf8) }

    /// Une valeur d'en-tête ne doit contenir ni guillemet ni retour à la ligne (un nom de séance
    /// pourrait sinon fermer l'en-tête et en injecter un autre).
    private static func headerSafe(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
        return String(String.UnicodeScalarView(cleaned.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }))
    }
}

struct HTTPError: LocalizedError {
    let status: Int
    let body: String

    /// Message court : la réponse brute du serveur (`body`) n'est ni affichée ni enregistrée.
    var errorDescription: String? {
        status == 401 ? "Erreur \(status) : connexion refusée, reconnecte ton compte."
                      : "Le serveur a répondu avec l'erreur \(status)."
    }

    /// Vérifie le statut HTTP d'une réponse.
    static func check(_ response: URLResponse, _ data: Data, accept: Set<Int> = Set(200..<300)) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard accept.contains(status) else {
            throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self))
        }
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
