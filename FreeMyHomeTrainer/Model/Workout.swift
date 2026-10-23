import Foundation

/// Cible de puissance d'un bloc : absolue en watts ou relative à la FTP.
enum Target: Hashable, Sendable {
    case watts(Int)
    case ftpPercent(Int)

    func watts(ftp: Int) -> Double {
        switch self {
        case .watts(let w): Double(w)
        case .ftpPercent(let p): Double(ftp) * Double(p) / 100
        }
    }

    var label: String {
        switch self {
        case .watts(let w): "\(w) W"
        case .ftpPercent(let p): "\(p) % FTP"
        }
    }
}

extension Target: Codable {
    // JSON : {"watts": 200} ou {"ftp": 90}
    private enum CodingKeys: String, CodingKey { case watts, ftp }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let w = try c.decodeIfPresent(Int.self, forKey: .watts) {
            self = .watts(w)
        } else if let p = try c.decodeIfPresent(Int.self, forKey: .ftp) {
            self = .ftpPercent(p)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Cible sans 'watts' ni 'ftp'"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .watts(let w): try c.encode(w, forKey: .watts)
        case .ftpPercent(let p): try c.encode(p, forKey: .ftp)
        }
    }
}

/// Un bloc de séance. Une seule structure (plutôt qu'un enum récursif) pour faciliter
/// l'édition via des bindings SwiftUI ; les champs inutiles selon `kind` sont ignorés.
struct WorkoutBlock: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case steady, ramp, repeats
    }

    var id = UUID()
    var kind: Kind
    var duration: TimeInterval = 300
    var target: Target = .ftpPercent(60)
    var endTarget: Target = .ftpPercent(60)
    var count: Int = 3
    var blocks: [WorkoutBlock] = []

    static func steady(_ duration: TimeInterval, _ target: Target) -> WorkoutBlock {
        WorkoutBlock(kind: .steady, duration: duration, target: target, endTarget: target)
    }

    static func ramp(_ duration: TimeInterval, from: Target, to: Target) -> WorkoutBlock {
        WorkoutBlock(kind: .ramp, duration: duration, target: from, endTarget: to)
    }

    static func repeats(_ count: Int, _ blocks: [WorkoutBlock]) -> WorkoutBlock {
        WorkoutBlock(kind: .repeats, count: count, blocks: blocks)
    }

    /// Durée totale du bloc, répétitions comprises.
    var totalDuration: TimeInterval {
        switch kind {
        case .steady, .ramp: duration
        case .repeats: Double(max(count, 0)) * blocks.reduce(0) { $0 + $1.totalDuration }
        }
    }
}

extension WorkoutBlock: Codable {
    // JSON volontairement simple pour pouvoir être produit par un LLM :
    // {"type":"steady","duration":600,"target":{"watts":200}}
    // {"type":"ramp","duration":600,"from":{"ftp":50},"to":{"ftp":75}}
    // {"type":"repeat","count":3,"blocks":[...]}
    private enum CodingKeys: String, CodingKey { case type, duration, target, from, to, count, blocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "steady":
            self = .steady(try c.decode(TimeInterval.self, forKey: .duration),
                           try c.decode(Target.self, forKey: .target))
        case "ramp":
            self = .ramp(try c.decode(TimeInterval.self, forKey: .duration),
                         from: try c.decode(Target.self, forKey: .from),
                         to: try c.decode(Target.self, forKey: .to))
        case "repeat", "repeats":
            self = .repeats(try c.decode(Int.self, forKey: .count),
                            try c.decode([WorkoutBlock].self, forKey: .blocks))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                   debugDescription: "Type de bloc inconnu : \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch kind {
        case .steady:
            try c.encode("steady", forKey: .type)
            try c.encode(duration, forKey: .duration)
            try c.encode(target, forKey: .target)
        case .ramp:
            try c.encode("ramp", forKey: .type)
            try c.encode(duration, forKey: .duration)
            try c.encode(target, forKey: .from)
            try c.encode(endTarget, forKey: .to)
        case .repeats:
            try c.encode("repeat", forKey: .type)
            try c.encode(count, forKey: .count)
            try c.encode(blocks, forKey: .blocks)
        }
    }
}

struct Workout: Codable, Hashable, Sendable {
    var name: String
    var notes: String = ""
    var blocks: [WorkoutBlock] = []

    var totalDuration: TimeInterval { blocks.reduce(0) { $0 + $1.totalDuration } }

    init(name: String, notes: String = "", blocks: [WorkoutBlock] = []) {
        self.name = name
        self.notes = notes
        self.blocks = blocks
    }

    // « notes » est facultatif dans le JSON (un LLM l'omettra souvent).
    private enum CodingKeys: String, CodingKey { case name, notes, blocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        blocks = try c.decode([WorkoutBlock].self, forKey: .blocks)
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func from(json data: Data) throws -> Workout {
        try JSONDecoder().decode(Workout.self, from: data)
    }
}

extension Workout {
    /// Séances proposées au premier lancement.
    static let samples: [Workout] = [
        Workout(name: "Sweet Spot 3x10'", notes: "3 blocs de 10 minutes à 90 % FTP.", blocks: [
            .ramp(600, from: .ftpPercent(45), to: .ftpPercent(70)),
            .repeats(3, [.steady(600, .ftpPercent(90)), .steady(300, .ftpPercent(55))]),
            .ramp(300, from: .ftpPercent(60), to: .ftpPercent(40)),
        ]),
        Workout(name: "Tempo 2x20'", notes: "Endurance haute, zone 3.", blocks: [
            .ramp(600, from: .ftpPercent(45), to: .ftpPercent(70)),
            .repeats(2, [.steady(1200, .ftpPercent(80)), .steady(300, .ftpPercent(55))]),
            .steady(300, .ftpPercent(50)),
        ]),
        Workout(name: "VO2 max 5x3'", notes: "Intervalles courts et intenses.", blocks: [
            .ramp(600, from: .ftpPercent(45), to: .ftpPercent(75)),
            .steady(300, .ftpPercent(60)),
            .repeats(5, [.steady(180, .ftpPercent(118)), .steady(180, .ftpPercent(50))]),
            .ramp(420, from: .ftpPercent(60), to: .ftpPercent(40)),
        ]),
        Workout(name: "Endurance 1h", notes: "Zone 2 continue.", blocks: [
            .ramp(300, from: .ftpPercent(45), to: .ftpPercent(65)),
            .steady(3000, .ftpPercent(68)),
            .steady(300, .ftpPercent(50)),
        ]),
    ]
}

/// Noms de séances uniques : « Nouvelle séance », « Nouvelle séance 2 », « Nouvelle séance 3 »…
enum WorkoutNaming {
    static let fallback = "Séance sans nom"

    /// Clé de comparaison : insensible à la casse, aux accents et aux espaces autour.
    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// `name` s'il est libre, sinon le même nom suivi du premier numéro disponible.
    static func unique(_ name: String, among existing: [String]) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        let taken = Set(existing.map(key))
        guard taken.contains(key(base)) else { return base }

        // « Séance 2 » déjà pris → on repart de « Séance » et on cherche le numéro suivant.
        var stem = base
        var number = 2
        if let match = base.firstMatch(of: /^(.*\S) (\d+)$/), let n = Int(match.2) {
            stem = String(match.1)
            number = n + 1
        }
        while taken.contains(key("\(stem) \(number)")) { number += 1 }
        return "\(stem) \(number)"
    }
}
