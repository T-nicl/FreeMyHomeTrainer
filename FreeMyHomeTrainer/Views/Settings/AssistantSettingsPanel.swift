import SwiftUI

/// Réglages de l'assistant de création de séances : adresse d'Ollama, modèle, test de connexion.
struct AssistantSettingsPanel: View {
    private enum Status: Equatable {
        case unknown, testing, ok(Int), failed(String)
    }

    @AppStorage(Settings.ollamaAddressKey) private var address = OllamaClient.defaultAddress
    @AppStorage(Settings.ollamaModelKey) private var model = OllamaClient.defaultModel
    @State private var installed: [String] = []
    @State private var status = Status.unknown

    var body: some View {
        LabeledContent("Adresse d'Ollama") {
            TextField("", text: $address, prompt: Text(OllamaClient.defaultAddress))
                .labelsHidden()
                .frame(width: 240)
        }
        if OllamaClient.baseURL(from: address) == nil {
            Text("Adresse invalide : http seulement sur ce Mac ou le réseau local, sinon https (ex. \(OllamaClient.defaultAddress)).").foregroundStyle(.orange)
        }
        LabeledContent("Modèle") {
            Picker("", selection: $model) {
                ForEach(Array(Set(installed + [model])).sorted(), id: \.self) { name in
                    Text(installed.contains(name) ? name : "\(name) (non installé)").tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 240)
        }
        LabeledContent("Connexion") {
            HStack {
                statusLabel
                Button("Tester") { Task { await test() } }
                    .disabled(status == .testing)
            }
        }
        .task(id: "\(address)|\(model)") {
            // Attend la fin de la saisie : pas de requête vers chaque adresse partielle.
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await test()
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .unknown: EmptyView()
        case .testing: ProgressView().controlSize(.small)
        case .ok(let count):
            Label(count > 1 ? "Ollama répond (\(count) modèles installés)" : "Ollama répond",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    /// Interroge Ollama : est-il lancé, et le modèle choisi est-il installé ?
    private func test() async {
        guard let url = OllamaClient.baseURL(from: address) else {
            installed = []
            status = .failed("Adresse invalide.")
            return
        }
        status = .testing
        do {
            let models = try await OllamaClient(baseURL: url).models()
            guard !Task.isCancelled else { return }          // un test plus récent fait foi
            installed = models
            status = installed.contains(model)
                ? .ok(installed.count)
                : .failed(OllamaClient.OllamaError.modelMissing(model).errorDescription ?? "")
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            installed = []
            status = .failed(error.localizedDescription)
        }
    }
}
