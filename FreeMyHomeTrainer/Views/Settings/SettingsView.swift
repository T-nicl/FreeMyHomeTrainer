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
