import SwiftUI

/// État de la fenêtre « Créer avec l'IA » : demande, séance proposée, ajustements.
@MainActor
@Observable
final class WorkoutAssistant {
    var request = ""
    var adjustment = ""
    private(set) var draft: WorkoutGenerator.Draft?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let makeGenerator: () -> WorkoutGenerator?

    init(draft: WorkoutGenerator.Draft? = nil, makeGenerator: @escaping () -> WorkoutGenerator? = { Settings.workoutGenerator }) {
        self.draft = draft
        self.makeGenerator = makeGenerator
    }

    func create() {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        start { try await $0.generate(request: text) }
    }

    func refine() {
        let text = adjustment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft, !text.isEmpty else { return }
        start { try await $0.refine(draft, instruction: text) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isWorking = false
    }

    /// Attend la fin de la génération en cours (tests).
    func finish() async { await task?.value }

    private func start(_ work: @escaping @Sendable (WorkoutGenerator) async throws -> WorkoutGenerator.Draft) {
        task?.cancel()
        guard let generator = makeGenerator() else {
            isWorking = false
            errorMessage = "Adresse d'Ollama invalide : corrige-la dans les Réglages."
            return
        }
        isWorking = true
        errorMessage = nil
        task = Task {
            do {
                let result = try await work(generator)
                guard !Task.isCancelled else { return }
                draft = result
                adjustment = ""
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                // En cas d'échec, la séance précédente reste affichée.
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Fenêtre « Créer avec l'IA » : la demande en français, un aperçu, des ajustements, puis l'ajout.
struct WorkoutAssistantSheet: View {
    static let examples = ["Tempo 3x10'", "Sweet spot 2x20'", "VO2 max 5x3'", "30/30 × 10 en 45 min",
                           "Endurance 1 h 30", "Pyramide 1-2-3-2-1' au seuil"]

    @Environment(\.dismiss) private var dismiss
    @AppStorage(Settings.ftpKey) private var ftp = 200
    @State private var assistant: WorkoutAssistant
    let onAdd: (Workout) -> Void

    init(assistant: WorkoutAssistant = WorkoutAssistant(), onAdd: @escaping (Workout) -> Void) {
        _assistant = State(initialValue: assistant)
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Créer une séance avec l'IA", systemImage: "sparkles").font(.title2.bold())
                        Text("Décris la séance en quelques mots : le modèle, installé sur ton Mac, la construit d'après ta FTP (\(ftp) W).")
                            .foregroundStyle(.secondary)
                    }
                    requestField
                    examples
                    status
                    if let draft = assistant.draft { preview(draft.workout) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Annuler") {
                    assistant.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Ajouter à mes séances") {
                    guard let workout = assistant.draft?.workout else { return }
                    onAdd(workout)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(assistant.draft == nil || assistant.isWorking)
            }
            .padding(16)
        }
        .frame(width: 640, height: 660)
        .onDisappear { assistant.cancel() }
    }

    private var requestField: some View {
        HStack(alignment: .bottom) {
            TextField("", text: $assistant.request, prompt: Text("ex. séance tempo 3x10'"), axis: .vertical)
                .labelsHidden()
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit { assistant.create() }
            Button("Créer") { assistant.create() }
                .disabled(assistant.isWorking || assistant.request.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var examples: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Self.examples, id: \.self) { example in
                Button(example) {
                    assistant.request = example
                    assistant.create()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .disabled(assistant.isWorking)
    }

    @ViewBuilder private var status: some View {
        if assistant.isWorking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Le modèle construit la séance… (souvent 20 à 60 s, plus la première fois : chargement du modèle)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Interrompre") { assistant.cancel() }.controlSize(.small)
            }
        } else if let message = assistant.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    private func preview(_ workout: Workout) -> some View {
        let timeline = WorkoutTimeline(workout: workout, ftp: ftp)
        return VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(workout.name).font(.title3.bold()).lineLimit(2)
            if !workout.notes.isEmpty {
                Text(workout.notes).foregroundStyle(.secondary).lineLimit(3)
            }
            WorkoutSummaryRow(timeline: timeline)
            WorkoutProfileChart(timeline: timeline, showFTPLine: true)
                .frame(height: 160)
            SanityBanner(warnings: WorkoutSanity.warnings(for: workout, ftp: ftp))
            HStack {
                TextField("", text: $assistant.adjustment,
                          prompt: Text("Ajuster… (ex. un peu plus dur, échauffement plus long)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.refine() }
                Button("Ajuster") { assistant.refine() }
                    .disabled(assistant.isWorking || assistant.adjustment.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Tu pourras encore tout modifier dans l'éditeur après l'ajout.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
