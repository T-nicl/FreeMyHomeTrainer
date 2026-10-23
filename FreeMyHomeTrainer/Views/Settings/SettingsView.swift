import SwiftUI

struct SettingsView: View {
    @AppStorage(Settings.ftpKey) private var ftp = 200
    @AppStorage(Settings.weightKey) private var weight = 70.0

    var body: some View {
        Form {
            Section {
                LabeledContent("FTP") {
                    HStack {
                        TextField("", value: $ftp, format: .number).labelsHidden().frame(width: 70)
                        Text("W")
                        Stepper("", value: $ftp, in: 50...600, step: 5).labelsHidden()
                    }
                    .fixedSize()
                }
                LabeledContent("Poids") {
                    HStack {
                        TextField("", value: $weight, format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .frame(width: 70)
                        Text("kg")
                    }
                    .fixedSize()
                }
                if weight > 0 {
                    LabeledContent("Rapport poids/puissance",
                                   value: String(format: "%.2f W/kg", Double(ftp) / weight))
                }
            } header: {
                Text("Profil")
            } footer: {
                Text("La FTP sert à calculer les cibles en % et la note d'intensité des séances.")
                    .foregroundStyle(.secondary)
            }

            Section("Comptes") {
                AccountsPanel()
            }

            Section {
                AssistantSettingsPanel()
            } header: {
                Text("Assistant IA")
            } footer: {
                Text("« Créer avec l'IA » (liste des séances) utilise Ollama, qui fait tourner le modèle sur ton Mac : rien n'est envoyé en ligne. Installation : « brew install ollama », « brew services start ollama », puis « ollama pull \(OllamaClient.defaultModel) » (≈ 4,7 Go). L'app Ollama (ollama.com) convient aussi.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Version", value: Self.version)
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .navigationTitle("Réglages")
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    /// « 0.1.0 (2) » : version affichée pour savoir laquelle tourne sur chaque Mac.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
