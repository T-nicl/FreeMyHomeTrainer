import AppKit
import Foundation
import SwiftUI
import Testing
@testable import FreeMyHomeTrainer

/// Faux serveur Ollama : rejoue des réponses et garde les requêtes reçues.
final class FakeOllama: @unchecked Sendable {
    typealias Reply = (status: Int, body: String)
    private let lock = NSLock()
    private var replies: [Result<Reply, URLError>]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Result<Reply, URLError>]) { self.replies = replies }

    var client: OllamaClient {
        OllamaClient(baseURL: URL(string: "http://localhost:11434")!) { request in
            try self.respond(to: request)
        }
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        let reply = replies.isEmpty ? .success((500, "plus de réponse prévue")) : replies.removeFirst()
        switch reply {
        case .failure(let error): throw error
        case .success(let (status, body)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    /// Corps JSON de la n-ième requête.
    func body(_ index: Int) throws -> [String: Any] {
        let data = try #require(requests[index].httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Réponse de /api/chat dont le contenu est `content`.
    static func chat(_ content: String) -> Result<Reply, URLError> {
        let json = try! JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": content],
                                                                "done": true])
        return .success((200, String(decoding: json, as: UTF8.self)))
    }
}

struct OllamaClientTests {
    @Test func listsInstalledModels() async throws {
        let fake = FakeOllama([.success((200, #"{"models":[{"name":"qwen2.5:7b"},{"name":"mistral:latest"}]}"#))])
        let models = try await fake.client.models()
        #expect(models == ["mistral:latest", "qwen2.5:7b"])
        #expect(fake.requests[0].url?.path == "/api/tags")
    }

    @Test func chatSendsModelSchemaAndMessages() async throws {
        let fake = FakeOllama([FakeOllama.chat(#"{"name":"x"}"#)])
        let reply = try await fake.client.chat(model: "qwen2.5:7b",
                                               messages: [.init(role: .system, content: "sys"),
                                                          .init(role: .user, content: "tempo")],
                                               format: WorkoutSchema.json)
        #expect(reply == #"{"name":"x"}"#)
        let body = try fake.body(0)
        #expect(fake.requests[0].url?.path == "/api/chat")
        #expect(fake.requests[0].httpMethod == "POST")
        #expect(body["model"] as? String == "qwen2.5:7b")
        #expect(body["stream"] as? Bool == false)
        #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == OllamaClient.maxReplyTokens)
        #expect((body["format"] as? [String: Any])?["type"] as? String == "object")
        #expect((body["messages"] as? [[String: Any]])?.map { $0["role"] as? String } == ["system", "user"])
    }

    @Test func ollamaNotRunningGivesAClearMessage() async {
        let fake = FakeOllama([.failure(URLError(.cannotConnectToHost))])
        await #expect(throws: OllamaClient.OllamaError.notRunning) { try await fake.client.models() }
        #expect(OllamaClient.OllamaError.notRunning.errorDescription?.contains("Ollama") == true)
    }

    @Test func missingModelSuggestsThePullCommand() async {
        let fake = FakeOllama([.success((404, #"{"error":"model 'qwen2.5:7b' not found"}"#))])
        await #expect(throws: OllamaClient.OllamaError.modelMissing("qwen2.5:7b")) {
            try await fake.client.chat(model: "qwen2.5:7b", messages: [], format: nil)
        }
        #expect(OllamaClient.OllamaError.modelMissing("qwen2.5:7b").errorDescription?
            .contains("ollama pull qwen2.5:7b") == true)
    }

    @Test func nonJSONResponseIsAnError() async {
        let fake = FakeOllama([.success((200, "<html>proxy</html>"))])
        await #expect(throws: OllamaClient.OllamaError.badResponse) {
            try await fake.client.chat(model: "m", messages: [], format: nil)
        }
    }

    @Test func serverErrorMessageIsShown() async {
        let fake = FakeOllama([.success((500, #"{"error":"out of memory"}"#))])
        await #expect(throws: OllamaClient.OllamaError.server("out of memory")) {
            try await fake.client.chat(model: "m", messages: [], format: nil)
        }
    }

    @Test func addressValidation() {
        #expect(OllamaClient.baseURL(from: "http://localhost:11434") != nil)
        #expect(OllamaClient.baseURL(from: " localhost:11434 ")?.absoluteString == "http://localhost:11434")
        #expect(OllamaClient.baseURL(from: "http://192.168.1.20:11434/") != nil)
        #expect(OllamaClient.baseURL(from: "file:///etc/passwd") == nil)
        #expect(OllamaClient.baseURL(from: "http://mac-mini.local:11434") != nil)
        #expect(OllamaClient.baseURL(from: "http://172.20.0.5:11434") != nil)
        // Hors du réseau local : la demande ne doit pas circuler en clair.
        #expect(OllamaClient.baseURL(from: "http://ollama.example.com") == nil)
        #expect(OllamaClient.baseURL(from: "http://8.8.8.8:11434") == nil)
        #expect(OllamaClient.baseURL(from: "http://172.32.0.1") == nil)
        #expect(OllamaClient.baseURL(from: "https://ollama.example.com") != nil)
        #expect(OllamaClient.baseURL(from: "") == nil)
    }
}

struct WorkoutGeneratorTests {
    /// Plan « tempo 3x10' » tel que le modèle le renvoie.
    static let tempo = #"""
    {"name":"Tempo 3x10'","notes":"Zone 3.","warmup_minutes":10,"series":[
      {"count":3,"efforts":[{"minutes":10,"watts":210}],"recovery_minutes":5,"recovery_watts":133}],
      "cooldown_minutes":5}
    """#

    func generator(_ fake: FakeOllama, ftp: Int = 245) -> WorkoutGenerator {
        WorkoutGenerator(client: fake.client, model: "qwen2.5:7b", ftp: ftp)
    }

    @Test func schemaRequiresEveryPartOfThePlan() throws {
        let data = try JSONEncoder().encode(WorkoutSchema.json)
        let schema = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(schema["required"] as? [String] == ["name", "notes", "warmup_minutes", "series", "cooldown_minutes"])
        let text = String(decoding: data, as: UTF8.self)
        for key in ["count", "efforts", "minutes", "watts", "recovery_minutes", "recovery_watts"] {
            #expect(text.contains(#""\#(key)""#))
        }
    }

    @Test func planBecomesAFullWorkout() throws {
        let plan = try JSONDecoder().decode(WorkoutPlan.self, from: Data(Self.tempo.utf8))
        let w = plan.workout(ftp: 245)
        #expect(w.blocks.count == 3)
        #expect(w.blocks[0].kind == .ramp && w.blocks[0].duration == 600)
        #expect(w.blocks[0].target == .watts(110) && w.blocks[0].endTarget == .watts(170))   // 45 → 70 % de 245
        #expect(w.blocks[1].kind == .repeats && w.blocks[1].count == 3)
        #expect(w.blocks[1].blocks.map(\.duration) == [600, 300])
        #expect(w.blocks[1].blocks[1].target == .watts(135))                                 // 133 → arrondi à 5 W
        #expect(w.blocks[2].kind == .ramp && w.blocks[2].duration == 300)
        #expect(w.totalDuration == 600 + 3 * 900 + 300)
    }

    @Test func singleSeriesNoRecoveryAndNoWarmup() throws {
        let json = #"""
        {"name":" 30/30 ","notes":"","warmup_minutes":0,"series":[
          {"count":1,"efforts":[{"minutes":50,"watts":165}],"recovery_minutes":0,"recovery_watts":0},
          {"count":10,"efforts":[{"minutes":0.5,"watts":290},{"minutes":0.25,"watts":400}],"recovery_minutes":0.5,"recovery_watts":120}],
          "cooldown_minutes":0}
        """#
        let w = try JSONDecoder().decode(WorkoutPlan.self, from: Data(json.utf8)).workout(ftp: 245)
        #expect(w.name == "30/30")
        #expect(w.blocks.count == 2)
        #expect(w.blocks[0].kind == .steady && w.blocks[0].duration == 3000)
        #expect(w.blocks[1].blocks.map(\.duration) == [30, 15, 30])
    }

    @Test func promptContainsFTPZonesAndLimits() throws {
        let prompt = WorkoutPrompt.system(ftp: 245)
        #expect(prompt.contains("245 W"))
        #expect(prompt.contains("\(WorkoutLimits.maxRepeatCount)"))
        #expect(prompt.contains("sweet spot"))
        #expect(prompt.contains("216"))        // 88 % de 245 W, bas du sweet spot
        // Les exemples sont des plans valides, en watts calculés pour cette FTP.
        for example in WorkoutPrompt.examples(ftp: 245) {
            let plan = try JSONDecoder().decode(WorkoutPlan.self, from: Data(example.json.utf8))
            #expect(throws: Never.self) { try plan.workout(ftp: 245).validate() }
        }
        #expect(WorkoutPrompt.examples(ftp: 245)[0].json.contains(#""watts":210"#))   // 85 % de 245
        #expect(WorkoutPrompt.examples(ftp: 300)[0].json.contains(#""watts":255"#))
    }

    @Test func generatesAValidWorkout() async throws {
        let fake = FakeOllama([FakeOllama.chat(Self.tempo)])
        let result = try await generator(fake).generate(request: "séance tempo 3x10'")
        #expect(result.workout.name == "Tempo 3x10'")
        #expect(result.workout.totalDuration == 600 + 3 * 900 + 300)
        let messages = try #require(fake.body(0)["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == WorkoutPrompt.system(ftp: 245))
        #expect(messages.last?["content"] as? String == "séance tempo 3x10'")
        #expect(try fake.body(0)["format"] != nil)
    }

    @Test func rejectedWorkoutIsRepairedOnce() async throws {
        let tooLong = #"{"name":"S","notes":"","warmup_minutes":10,"series":[{"count":1,"efforts":[{"minutes":2000,"watts":200}],"recovery_minutes":0,"recovery_watts":0}],"cooldown_minutes":5}"#
        let fake = FakeOllama([FakeOllama.chat(tooLong), FakeOllama.chat(Self.tempo)])
        let result = try await generator(fake).generate(request: "très long")
        #expect(result.workout.name == "Tempo 3x10'")
        #expect(fake.requests.count == 2)
        let retry = try #require(fake.body(1)["messages"] as? [[String: Any]])
        #expect(retry.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect((retry.last?["content"] as? String)?.contains("24 h") == true)
        // La conversation gardée ne contient pas l'échec réparé.
        #expect(result.conversation.map(\.role) == [.system, .user, .assistant])
    }

    @Test func failsAfterASecondRejection() async {
        let fake = FakeOllama([FakeOllama.chat("pas du JSON"), FakeOllama.chat(#"{"name":"S"}"#)])
        await #expect(throws: WorkoutGenerator.GenerationError.self) {
            try await generator(fake).generate(request: "x")
        }
        #expect(fake.requests.count == 2)
    }

    @Test func ollamaErrorsAreNotRetried() async {
        let fake = FakeOllama([.failure(URLError(.cannotConnectToHost))])
        await #expect(throws: OllamaClient.OllamaError.notRunning) {
            try await generator(fake).generate(request: "x")
        }
        #expect(fake.requests.count == 1)
    }

    @Test func refineSendsThePlanAndInstruction() async throws {
        let fake = FakeOllama([FakeOllama.chat(Self.tempo), FakeOllama.chat(Self.tempo)])
        let gen = generator(fake)
        let first = try await gen.generate(request: "tempo 3x10'")
        let refined = try await gen.refine(first, instruction: "un peu plus dur")
        let messages = try #require(fake.body(1)["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user", "assistant", "user"])
        #expect(messages[2]["content"] as? String == Self.tempo)
        #expect((messages[3]["content"] as? String)?.contains("un peu plus dur") == true)
        #expect(refined.conversation.count == 5)
    }

    @Test func longConversationsAreTrimmed() async throws {
        let fake = FakeOllama(Array(repeating: FakeOllama.chat(Self.tempo), count: 12))
        let gen = generator(fake)
        var result = try await gen.generate(request: "tempo")
        for i in 0..<10 { result = try await gen.refine(result, instruction: "ajustement \(i)") }
        let messages = try #require(fake.body(10)["messages"] as? [[String: Any]])
        #expect(messages.count <= WorkoutGenerator.maxMessages)
        #expect(messages.first?["role"] as? String == "system")
        #expect(messages[1]["content"] as? String == "tempo")     // la demande d'origine reste
        #expect(messages.last?["content"].map { "\($0)" }?.contains("ajustement 9") == true)
    }
}

@MainActor
struct WorkoutAssistantTests {
    func assistant(_ fake: FakeOllama) -> WorkoutAssistant {
        WorkoutAssistant { WorkoutGenerator(client: fake.client, model: "qwen2.5:7b", ftp: 245) }
    }

    @Test func createShowsTheProposedWorkout() async {
        let fake = FakeOllama([FakeOllama.chat(WorkoutGeneratorTests.tempo)])
        let a = assistant(fake)
        a.request = "  tempo 3x10'  "
        a.create()
        #expect(a.isWorking)
        await a.finish()
        #expect(!a.isWorking)
        #expect(a.draft?.workout.name == "Tempo 3x10'")
        #expect(a.errorMessage == nil)
    }

    @Test func emptyRequestDoesNothing() async {
        let fake = FakeOllama([])
        let a = assistant(fake)
        a.request = "   "
        a.create()
        await a.finish()
        #expect(fake.requests.isEmpty)
        #expect(!a.isWorking)
    }

    @Test func ollamaStoppedShowsAMessageAndCreatesNothing() async {
        let a = assistant(FakeOllama([.failure(URLError(.cannotConnectToHost))]))
        a.request = "tempo"
        a.create()
        await a.finish()
        #expect(a.draft == nil)
        #expect(a.errorMessage == OllamaClient.OllamaError.notRunning.errorDescription)
    }

    @Test func failedAdjustmentKeepsThePreviousWorkout() async {
        let fake = FakeOllama([FakeOllama.chat(WorkoutGeneratorTests.tempo), .failure(URLError(.timedOut))])
        let a = assistant(fake)
        a.request = "tempo"
        a.create()
        await a.finish()
        a.adjustment = "plus dur"
        a.refine()
        await a.finish()
        #expect(a.draft?.workout.name == "Tempo 3x10'")
        #expect(a.adjustment == "plus dur")             // la consigne reste pour réessayer
        #expect(a.errorMessage == OllamaClient.OllamaError.timedOut.errorDescription)
    }

    @Test func invalidAddressIsReported() {
        let a = WorkoutAssistant { nil }
        a.request = "tempo"
        a.create()
        #expect(a.errorMessage?.contains("Adresse") == true)
        #expect(!a.isWorking)
    }

    /// La fenêtre avec un aperçu s'affiche bien (pas de mise en page insoluble, cf. CLAUDE.md).
    @Test func sheetWithPreviewIsNotBlank() throws {
        let workout = try JSONDecoder().decode(WorkoutPlan.self, from: Data(WorkoutGeneratorTests.tempo.utf8)).workout(ftp: 245)
        let draft = WorkoutGenerator.Draft(workout: workout, conversation: [])
        let hosting = NSHostingView(rootView: WorkoutAssistantSheet(assistant: WorkoutAssistant(draft: draft) { nil },
                                                                    onAdd: { _ in }))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 660)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let background = rep.colorAt(x: rep.pixelsWide - 4, y: rep.pixelsHigh / 2)
        var differing = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                total += 1
                if rep.colorAt(x: x, y: y) != background { differing += 1 }
            }
        }
        #expect(Double(differing) / Double(total) > 0.08)
    }
}

/// Évaluation avec le vrai modèle (lente, désactivée par défaut) :
/// `TEST_RUNNER_OLLAMA_EVAL=1 xcodebuild … test -only-testing:FreeMyHomeTrainerTests/OllamaEvaluation`
struct OllamaEvaluation {
    static let enabled = ProcessInfo.processInfo.environment["OLLAMA_EVAL"] == "1"
    static let requests = ["séance tempo 3x10'", "sweet spot 2x20'", "VO2 max 5x3'", "30/30 × 10, 45 minutes en tout",
                           "endurance 1 h 30", "pyramide 1-2-3-2-1' au seuil", "seuil 4x8' avec 4' de récup",
                           "séance courte de 30 minutes pour se dérouiller", "2 × (8 × 1' à fond / 1' récup)",
                           "over-under 3 x 9' (1' à 105 %, 2' à 90 %)"]

    static func describe(_ blocks: [WorkoutBlock]) -> String {
        blocks.map { b in
            switch b.kind {
            case .steady: "\(Format.duration(b.duration)) \(b.target.label)"
            case .ramp: "\(Format.duration(b.duration)) \(b.target.label)→\(b.endTarget.label)"
            case .repeats: "\(b.count)×[\(describe(b.blocks))]"
            }
        }.joined(separator: " | ")
    }

    @Test(.enabled(if: enabled), .timeLimit(.minutes(30)))
    func realModel() async {
        let model = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? OllamaClient.defaultModel
        let gen = WorkoutGenerator(client: OllamaClient(baseURL: URL(string: OllamaClient.defaultAddress)!),
                                   model: model, ftp: 245)
        var valid = 0
        var first: WorkoutGenerator.Draft?
        for request in Self.requests {
            let start = Date()
            do {
                let draft = try await gen.generate(request: request)
                valid += 1
                if first == nil { first = draft }
                let warnings = WorkoutSanity.warnings(for: draft.workout, ftp: 245)
                print("EVAL ✓ « \(request) » (\(Int(Date().timeIntervalSince(start))) s) → \(draft.workout.name), "
                      + "\(Format.duration(draft.workout.totalDuration)) : \(Self.describe(draft.workout.blocks))"
                      + (warnings.isEmpty ? "" : " ⚠︎ \(warnings.joined(separator: " ; "))"))
            } catch {
                print("EVAL ✗ « \(request) » : \(error.localizedDescription)")
            }
        }
        if let first {
            for instruction in ["un peu plus dur", "échauffement plus long"] {
                do {
                    let refined = try await gen.refine(first, instruction: instruction)
                    print("EVAL ↻ « \(instruction) » → \(Format.duration(refined.workout.totalDuration)) : \(Self.describe(refined.workout.blocks))")
                } catch {
                    print("EVAL ✗ « \(instruction) » : \(error.localizedDescription)")
                }
            }
        }
        print("EVAL \(valid)/\(Self.requests.count) séances valides")
    }
}
