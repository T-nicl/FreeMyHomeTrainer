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
        if let match = base.firstMatch(of: /^(.*\S) (\d{1,9})$/), let n = Int(match.2) {
            stem = String(match.1)
            number = n + 1
        }
        while taken.contains(key("\(stem) \(number)")) { number += 1 }
        return "\(stem) \(number)"
    }
}

/// Limites d'une séance. Une séance venue de l'extérieur (JSON, LLM, ami) qui les dépasse est
/// refusée (`importJSON`) ; une séance déjà enregistrée est ramenée dans les limites au
/// chargement (`sanitized`), pour qu'aucune donnée ne puisse figer ou planter l'app.
enum WorkoutLimits {
    static let maxRepeatCount = 50
    /// Niveaux d'imbrication des répétitions.
    static let maxDepth = 4
    /// Segments une fois les répétitions déroulées (filet de sécurité du déroulé).
    static let maxSegments = 5_000
    static let minBlockDuration: TimeInterval = 1
    static let maxBlockDuration: TimeInterval = 24 * 3600
    static let maxTotalDuration: TimeInterval = 24 * 3600
    static let maxWatts = 2_500
    static let maxFTPPercent = 1_000
    /// Blocs et répétitions au total, avant déroulé.
    static let maxNodes = 2_000
    static let maxNameLength = 100
    static let maxNotesLength = 5_000
    /// Taille maximale d'un JSON importé.
    static let maxImportBytes = 256_000
}

struct WorkoutValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension Int {
    /// Conversion qui ne plante jamais : NaN → 0, valeurs infinies ou énormes bornées.
    init(safe value: Double) {
        guard value.isFinite else {
            self = value.isNaN ? 0 : (value > 0 ? Int(Int32.max) : Int(Int32.min))
            return
        }
        self = Int(Swift.min(Swift.max(value.rounded(), Double(Int32.min)), Double(Int32.max)))
    }
}

extension Target {
    fileprivate var isWithinLimits: Bool {
        switch self {
        case .watts(let w): (0...WorkoutLimits.maxWatts).contains(w)
        case .ftpPercent(let p): (0...WorkoutLimits.maxFTPPercent).contains(p)
        }
    }

    fileprivate var clamped: Target {
        switch self {
        case .watts(let w): .watts(Swift.min(Swift.max(w, 0), WorkoutLimits.maxWatts))
        case .ftpPercent(let p): .ftpPercent(Swift.min(Swift.max(p, 0), WorkoutLimits.maxFTPPercent))
        }
    }

    fileprivate var spoken: String {
        switch self {
        case .watts(let w): "\(w) W"
        case .ftpPercent(let p): "\(p) % FTP"
        }
    }
}

extension Workout {
    /// Séance venue de l'extérieur (JSON, LLM, ami) : décodée puis validée.
    static func importJSON(_ data: Data) throws -> Workout {
        guard data.count <= WorkoutLimits.maxImportBytes else {
            throw WorkoutValidationError(message: "Fichier de séance trop volumineux (\(data.count / 1000) Ko, 256 Ko au maximum).")
        }
        let workout = try from(json: data)
        try workout.validate()
        return workout
    }

    /// Vérifie que la séance respecte `WorkoutLimits` ; sinon, erreur en français.
    func validate() throws {
        func fail(_ message: String) -> WorkoutValidationError { WorkoutValidationError(message: message) }
        guard name.count <= WorkoutLimits.maxNameLength else {
            throw fail("Nom de \(name.count) caractères : \(WorkoutLimits.maxNameLength) au maximum.")
        }
        guard notes.count <= WorkoutLimits.maxNotesLength else {
            throw fail("Notes de \(notes.count) caractères : \(WorkoutLimits.maxNotesLength) au maximum.")
        }
        guard blocks.nodeCount <= WorkoutLimits.maxNodes else {
            throw fail("Séance de \(blocks.nodeCount) blocs : \(WorkoutLimits.maxNodes) au maximum.")
        }
        var segments = 0.0

        func check(_ blocks: [WorkoutBlock], depth: Int, multiplier: Double) throws {
            for b in blocks {
                switch b.kind {
                case .steady, .ramp:
                    guard b.duration.isFinite,
                          (WorkoutLimits.minBlockDuration...WorkoutLimits.maxBlockDuration).contains(b.duration) else {
                        throw fail("Bloc de \(Format.duration(b.duration)) : durée entre 1 s et 24 h.")
                    }
                    for t in b.kind == .ramp ? [b.target, b.endTarget] : [b.target] where !t.isWithinLimits {
                        throw fail("Cible de \(t.spoken) : 0 à \(WorkoutLimits.maxWatts) W ou 0 à \(WorkoutLimits.maxFTPPercent) % FTP.")
                    }
                    segments += multiplier
                case .repeats:
                    guard (1...WorkoutLimits.maxRepeatCount).contains(b.count) else {
                        throw fail("\(b.count) répétitions : \(WorkoutLimits.maxRepeatCount) au maximum.")
                    }
                    guard depth < WorkoutLimits.maxDepth else {
                        throw fail("Répétitions imbriquées sur plus de \(WorkoutLimits.maxDepth) niveaux.")
                    }
                    guard b.producesSegments else {
                        throw fail("Répétition vide : ajoute au moins un bloc dedans.")
                    }
                    try check(b.blocks, depth: depth + 1, multiplier: multiplier * Double(b.count))
                }
            }
        }

        try check(blocks, depth: 0, multiplier: 1)
        guard segments <= Double(WorkoutLimits.maxSegments) else {
            throw fail("Séance trop découpée : \(Int(safe: segments)) blocs une fois déroulée, \(WorkoutLimits.maxSegments) au maximum.")
        }
        guard totalDuration <= WorkoutLimits.maxTotalDuration else {
            throw fail("Séance de \(Format.duration(totalDuration)) : 24 h au maximum.")
        }
    }

    /// Copie ramenée dans les limites — pour une séance déjà enregistrée, qu'on ne veut ni
    /// refuser ni laisser figer l'app : durées et cibles bornées, blocs de durée nulle ou
    /// invalide retirés, répétitions trop profondes aplaties, répétitions vides retirées,
    /// nombre de blocs, nom et notes plafonnés.
    func sanitized() -> Workout {
        var budget = WorkoutLimits.maxNodes

        func clean(_ blocks: [WorkoutBlock], depth: Int) -> [WorkoutBlock] {
            var out: [WorkoutBlock] = []
            for b in blocks where budget > 0 {
                switch b.kind {
                case .steady, .ramp:
                    guard b.duration.isFinite, b.duration > 0 else { continue }
                    var c = b
                    c.duration = Swift.min(Swift.max(b.duration, WorkoutLimits.minBlockDuration),
                                           WorkoutLimits.maxBlockDuration)
                    c.target = b.target.clamped
                    c.endTarget = b.endTarget.clamped
                    budget -= 1
                    out.append(c)
                case .repeats:
                    // Au-delà de la profondeur maximale, on garde les blocs sans la répétition.
                    guard depth < WorkoutLimits.maxDepth else {
                        out += clean(b.blocks.leaves, depth: depth)
                        continue
                    }
                    budget -= 1
                    var c = b
                    c.count = Swift.min(Swift.max(b.count, 1), WorkoutLimits.maxRepeatCount)
                    c.blocks = clean(b.blocks, depth: depth + 1)
                    if !c.blocks.isEmpty { out.append(c) }
                }
            }
            return out
        }

        var copy = self
        copy.name = String(name.prefix(WorkoutLimits.maxNameLength))
        copy.notes = String(notes.prefix(WorkoutLimits.maxNotesLength))
        copy.blocks = clean(blocks, depth: 0)
        return copy
    }
}
