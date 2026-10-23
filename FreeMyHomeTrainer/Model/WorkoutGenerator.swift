import Foundation

/// Ce que le modèle remplit : un plan de séance simple (échauffement, séries, retour au calme),
/// que l'app transforme en blocs. Un modèle de 7 Mds de paramètres compose mal l'arbre de blocs
/// lui-même (récupérations, échauffement oubliés, répétitions mal imbriquées, minutes et secondes
/// confondues) ; avec ce plan, chaque élément est un champ obligatoire du schéma.
struct WorkoutPlan: Codable, Sendable {
    struct Effort: Codable, Sendable {
        var minutes: Double
        var watts: Int
    }

    /// `count` fois : les efforts enchaînés, puis la récupération (absente si 0 minute).
    struct Series: Codable, Sendable {
        var count: Int
        var efforts: [Effort]
        var recoveryMinutes: Double
        var recoveryWatts: Int

        private enum CodingKeys: String, CodingKey {
            case count, efforts, recoveryMinutes = "recovery_minutes", recoveryWatts = "recovery_watts"
        }
    }

    var name: String
    var notes: String
    var warmupMinutes: Double
    var series: [Series]
    var cooldownMinutes: Double

    private enum CodingKeys: String, CodingKey {
        case name, notes, warmupMinutes = "warmup_minutes", series, cooldownMinutes = "cooldown_minutes"
    }

    /// Séance correspondante : échauffement en rampe (45 → 70 % FTP), séries (répétition si
    /// `count` > 1), retour au calme en rampe (60 → 40 % FTP). Watts arrondis à 5 W.
    func workout(ftp: Int) -> Workout {
        func seconds(_ minutes: Double) -> TimeInterval { TimeInterval(Int(safe: minutes * 60)) }
        func watts(_ value: Double) -> Target { .watts(Int(safe: value / 5) * 5) }
        func percent(_ p: Double) -> Target { watts(Double(ftp) * p / 100) }

        var blocks: [WorkoutBlock] = []
        if warmupMinutes > 0 { blocks.append(.ramp(seconds(warmupMinutes), from: percent(45), to: percent(70))) }
        for s in series {
            var set = s.efforts.map { WorkoutBlock.steady(seconds($0.minutes), watts(Double($0.watts))) }
            if s.recoveryMinutes > 0 { set.append(.steady(seconds(s.recoveryMinutes), watts(Double(s.recoveryWatts)))) }
            if s.count > 1 { blocks.append(.repeats(s.count, set)) } else { blocks += set }
        }
        if cooldownMinutes > 0 { blocks.append(.ramp(seconds(cooldownMinutes), from: percent(60), to: percent(40))) }
        return Workout(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                       notes: notes.trimmingCharacters(in: .whitespacesAndNewlines), blocks: blocks)
    }
}

/// Schéma JSON du plan, transmis à Ollama (`format`) : la réponse du modèle respecte cette
/// structure quel que soit le modèle.
enum WorkoutSchema {
    static let json: JSONValue = object([
        ("name", .object([("type", .string("string"))])),
        ("notes", .object([("type", .string("string"))])),
        ("warmup_minutes", minutes),
        ("series", array(of: object([
            ("count", integer(1...WorkoutLimits.maxRepeatCount)),
            ("efforts", array(of: object([("minutes", minutes), ("watts", integer(0...2000))]))),
            ("recovery_minutes", minutes),
            ("recovery_watts", integer(0...2000)),
        ]))),
        ("cooldown_minutes", minutes),
    ])

    private static let minutes: JSONValue = .object([("type", .string("number")), ("minimum", .int(0)),
                                                     ("maximum", .int(Int(WorkoutLimits.maxBlockDuration / 60)))])

    private static func integer(_ range: ClosedRange<Int>) -> JSONValue {
        .object([("type", .string("integer")), ("minimum", .int(range.lowerBound)), ("maximum", .int(range.upperBound))])
    }

    /// Objet dont toutes les propriétés sont obligatoires.
    private static func object(_ properties: [(String, JSONValue)]) -> JSONValue {
        .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(properties.map { .string($0.0) })),
        ])
    }

    private static func array(of items: JSONValue) -> JSONValue {
        .object([("type", .string("array")), ("minItems", .int(1)), ("items", items)])
    }
}

/// Consignes données au modèle : format du plan, FTP et zones en watts, vocabulaire de l'entraînement.
enum WorkoutPrompt {
    /// Plans montrés en exemple, en watts calculés pour la FTP du cycliste (un petit modèle
    /// recopie volontiers les valeurs des exemples).
    static func examples(ftp: Int) -> [(request: String, json: String)] {
        func w(_ percent: Int) -> Int { Int(safe: Double(ftp) * Double(percent) / 500) * 5 }
        return [
            ("tempo 3x10'", #"""
            {"name":"Tempo 3x10'","notes":"Trois blocs de 10 minutes en zone 3.","warmup_minutes":10,"series":[
            {"count":3,"efforts":[{"minutes":10,"watts":\#(w(85))}],"recovery_minutes":5,"recovery_watts":\#(w(55))}],
            "cooldown_minutes":5}
            """#),
            ("30/30 × 10", #"""
            {"name":"30/30 x 10","notes":"10 fois 30 secondes vite, 30 secondes lent.","warmup_minutes":10,"series":[
            {"count":10,"efforts":[{"minutes":0.5,"watts":\#(w(120))}],"recovery_minutes":0.5,"recovery_watts":\#(w(50))}],
            "cooldown_minutes":5}
            """#),
            ("pyramide 2-4-6-4-2' en sweet spot", #"""
            {"name":"Pyramide sweet spot","notes":"Efforts de 2, 4, 6, 4 puis 2 minutes.","warmup_minutes":10,"series":[
            {"count":1,"efforts":[{"minutes":2,"watts":\#(w(90))}],"recovery_minutes":2,"recovery_watts":\#(w(55))},
            {"count":1,"efforts":[{"minutes":4,"watts":\#(w(90))}],"recovery_minutes":3,"recovery_watts":\#(w(55))},
            {"count":1,"efforts":[{"minutes":6,"watts":\#(w(90))}],"recovery_minutes":3,"recovery_watts":\#(w(55))},
            {"count":1,"efforts":[{"minutes":4,"watts":\#(w(90))}],"recovery_minutes":2,"recovery_watts":\#(w(55))},
            {"count":1,"efforts":[{"minutes":2,"watts":\#(w(90))}],"recovery_minutes":0,"recovery_watts":0}],
            "cooldown_minutes":5}
            """#),
            ("2 × (3' au seuil + 1' à 110 %)", #"""
            {"name":"Seuil 2 x (3' + 1')","notes":"Deux fois 3 minutes au seuil enchaînées avec 1 minute plus dure.","warmup_minutes":10,"series":[
            {"count":2,"efforts":[{"minutes":3,"watts":\#(w(100))},{"minutes":1,"watts":\#(w(110))}],"recovery_minutes":4,"recovery_watts":\#(w(55))}],
            "cooldown_minutes":5}
            """#),
            ("endurance 1 h", #"""
            {"name":"Endurance 1 h","notes":"Une heure en zone 2.","warmup_minutes":5,"series":[
            {"count":1,"efforts":[{"minutes":50,"watts":\#(w(68))}],"recovery_minutes":0,"recovery_watts":0}],
            "cooldown_minutes":5}
            """#),
        ]
    }

    static func system(ftp: Int) -> String {
        func w(_ percent: Int) -> Int { Int(safe: Double(ftp) * Double(percent) / 100) }
        let shown = examples(ftp: ftp).map { "Demande « \($0.request) » :\n\($0.json)" }.joined(separator: "\n\n")
        return """
        Tu es un entraîneur de cyclisme. Tu prépares des séances de home trainer en mode ERG \
        (puissance imposée) et tu réponds uniquement par un plan de séance au format JSON.

        Cycliste : FTP de \(ftp) W. Zones de puissance :
        - Z1 récupération : moins de \(w(56)) W
        - Z2 endurance : \(w(56)) à \(w(75)) W
        - Z3 tempo : \(w(76)) à \(w(90)) W
        - sweet spot : \(w(88)) à \(w(94)) W
        - Z4 seuil : \(w(95)) à \(w(105)) W
        - Z5 VO2 max : \(w(106)) à \(w(120)) W
        - Z6 anaérobie : \(w(121)) à \(w(150)) W ; sprint : plus de \(w(150)) W

        Plan :
        - "name" : nom court en français ; "notes" : une phrase qui décrit la séance.
        - "warmup_minutes" : durée de l'échauffement (l'app le dessine) ; 10 sauf demande contraire.
        - "series" : le corps de la séance, dans l'ordre. Une série = "count" fois : les "efforts"
          enchaînés (durée en minutes, puissance en watts), puis "recovery_minutes" de récupération
          à "recovery_watts".
        - "cooldown_minutes" : durée du retour au calme (l'app le dessine) ; 5 sauf demande contraire.
        - Durées en MINUTES : 10 = 10 minutes, 0.5 = 30 secondes, 90 = 1 h 30.

        Règles :
        - « 3x10' » = UNE série avec "count": 3 et un effort de 10 minutes. « 5x3' » = "count": 5.
        - Récupération si elle n'est pas précisée : 5 minutes après 8 à 20 minutes d'effort, autant
          que l'effort pour 1 à 5 minutes, 0.5 minute pour du 30/30 ; vers \(w(55)) W. Pas de
          récupération (0) seulement pour un effort unique et long (endurance).
        - Puissances : « tempo » vers \(w(85)) W ; « sweet spot » vers \(w(90)) W ; « seuil » vers \(w(100)) W ;
          « VO2 » vers \(w(115)) W ; « endurance » vers \(w(68)) W ; « à fond » sur 1 minute vers \(w(130)) W.
          Un pourcentage (« 105 % ») s'applique à la FTP.
        - Pyramide ou efforts tous différents : une série par effort, avec "count": 1.
        - Durée totale = échauffement + retour au calme + pour chaque série "count" × (efforts +
          récupération). Si une durée totale est demandée, respecte-la.
        - La séance doit rester réaliste pour cette FTP ; \(WorkoutLimits.maxRepeatCount) répétitions au plus.
        - Quand on te demande d'ajuster la séance, renvoie le plan complet modifié.

        Exemples (pour cette FTP) :

        \(shown)
        """
    }
}

/// Crée une séance à partir d'une demande en français, puis l'ajuste (« un peu plus dur »…).
/// La réponse du modèle (un `WorkoutPlan`) devient une séance validée comme une séance importée ;
/// si elle est refusée, le modèle a droit à un seul nouvel essai, avec le message d'erreur.
struct WorkoutGenerator: Sendable {
    typealias Message = OllamaClient.Message

    /// Conversation envoyée au plus : consignes, demande d'origine et derniers échanges.
    static let maxMessages = 10

    /// Séance proposée et conversation qui y a mené (pour l'ajuster ensuite).
    struct Draft: Sendable {
        var workout: Workout
        var conversation: [Message]
    }

    struct GenerationError: LocalizedError {
        let reason: String
        var errorDescription: String? {
            "Le modèle n'a pas produit de séance valide (\(reason)). Reformule la demande ou essaie un autre modèle."
        }
    }

    let client: OllamaClient
    let model: String
    let ftp: Int

    func generate(request: String) async throws -> Draft {
        try await run([Message(role: .system, content: WorkoutPrompt.system(ftp: ftp)),
                       Message(role: .user, content: request)])
    }

    /// La conversation se termine par le plan de la séance affichée : le modèle le modifie.
    func refine(_ draft: Draft, instruction: String) async throws -> Draft {
        let messages = draft.conversation + [
            Message(role: .user, content: "Modifie cette séance : \(instruction)\nRenvoie le plan complet."),
        ]
        return try await run(Self.trimmed(messages))
    }

    /// Garde les consignes, la demande d'origine et les derniers échanges.
    static func trimmed(_ messages: [Message]) -> [Message] {
        guard messages.count > maxMessages else { return messages }
        return Array(messages.prefix(2)) + messages.suffix(maxMessages - 2)
    }

    private func run(_ messages: [Message]) async throws -> Draft {
        let reply = try await client.chat(model: model, messages: messages, format: WorkoutSchema.json)
        do {
            return Draft(workout: try parse(reply), conversation: messages + [Message(role: .assistant, content: reply)])
        } catch {
            let retry = messages + [
                Message(role: .assistant, content: reply),
                Message(role: .user, content: "Ce plan est refusé : \(Self.describe(error)) Corrige-le et renvoie le plan complet."),
            ]
            let second = try await client.chat(model: model, messages: retry, format: WorkoutSchema.json)
            do {
                return Draft(workout: try parse(second), conversation: messages + [Message(role: .assistant, content: second)])
            } catch {
                throw GenerationError(reason: Self.describe(error))
            }
        }
    }

    /// Réponse → plan → séance validée (`WorkoutLimits`).
    private func parse(_ reply: String) throws -> Workout {
        guard reply.utf8.count <= WorkoutLimits.maxImportBytes else {
            throw WorkoutValidationError(message: "Réponse trop longue.")
        }
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: Data(reply.utf8))
        let workout = plan.workout(ftp: ftp)
        guard !workout.blocks.isEmpty else { throw WorkoutValidationError(message: "Séance vide.") }
        try workout.validate()
        return workout
    }

    private static func describe(_ error: Error) -> String {
        if let validation = error as? WorkoutValidationError { return validation.message }
        if error is DecodingError { return "ce n'est pas un plan au format JSON attendu." }
        return error.localizedDescription
    }
}
