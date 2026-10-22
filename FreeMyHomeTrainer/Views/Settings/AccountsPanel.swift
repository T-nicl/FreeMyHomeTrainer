import SwiftUI

/// Bouton « Connecter Garmin » : une seule connexion suffit, seuls les jetons sont conservés
/// (dans le Trousseau), jamais le mot de passe. Strava est alimenté par Garmin Connect.
struct AccountsPanel: View {
    /// Version compacte (écran Rouler) : sans les options ni l'aide Strava détaillée.
    var compact = false

    @Environment(UploadCenter.self) private var uploads
    @AppStorage(Settings.garminAutoUploadKey) private var garminAuto = true

    @State private var showLogin = false

    static let garminBlue = Color(red: 0.0, green: 0.47, blue: 0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "applewatch")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Self.garminBlue, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Garmin Connect").font(.headline)
                    if uploads.garminConnected {
                        Label("Connecté", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else {
                        Text("Non connecté").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if uploads.garminConnected {
                    Button("Déconnecter") {
                        uploads.garmin.disconnect()
                        uploads.refreshAccounts()
                    }
                    .fixedSize()
                } else {
                    Button("Connecter Garmin") { showLogin = true }
                        .buttonStyle(.borderedProminent)
                        .tint(Self.garminBlue)
                        .fixedSize()
                }
            }
            .padding(10)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))

            if !compact {
                if uploads.garminConnected {
                    Toggle("Envoyer automatiquement sur Garmin après chaque sortie", isOn: $garminAuto)
                        .padding(.leading, 4)
                }
                Label {
                    Text("**Pour Strava** : dans Garmin Connect, ouvre Paramètres › Applications connectées › Strava. Tes sorties y seront ensuite transmises automatiquement.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.triangle.branch")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if uploads.garminConnected {
                Text("Envoi automatique vers Garmin, puis Strava via Garmin Connect.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .sheet(isPresented: $showLogin) { GarminLoginSheet() }
    }
}

// MARK: - Connexion Garmin

/// Fenêtre de connexion Garmin : e-mail + mot de passe, puis code de vérification si
/// la double authentification est activée sur le compte.
struct GarminLoginSheet: View {
    @Environment(UploadCenter.self) private var uploads
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "applewatch")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(AccountsPanel.garminBlue, in: RoundedRectangle(cornerRadius: 14))

            VStack(spacing: 6) {
                Text("Connexion à Garmin Connect").font(.title2.weight(.bold))
                Text(needsCode ? "Saisis le code de vérification envoyé par Garmin."
                               : "Ton mot de passe sert uniquement à te connecter : il n'est pas enregistré.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                if needsCode {
                    TextField("", text: $code, prompt: Text("Code à 6 chiffres"))
                        .textContentType(.oneTimeCode)
                } else {
                    TextField("", text: $email, prompt: Text("E-mail"))
                        .textContentType(.username)
                    SecureField("", text: $password, prompt: Text("Mot de passe"))
                        .textContentType(.password)
                }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .disabled(busy)

            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(needsCode ? "Valider" : "Se connecter") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(AccountsPanel.garminBlue)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || (needsCode ? code.isEmpty : email.isEmpty || password.isEmpty))
            }
            .controlSize(.large)

            Text("Envoi non officiel : il peut cesser de fonctionner si Garmin change sa connexion.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(width: 380)
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if needsCode {
                try await uploads.garmin.submitMFA(code: code.trimmingCharacters(in: .whitespaces))
            } else if try await uploads.garmin.login(email: email.trimmingCharacters(in: .whitespaces),
                                                     password: password) == .needsMFACode {
                password = ""
                needsCode = true
                return
            }
            password = ""
            uploads.refreshAccounts()
            dismiss()
        } catch {
            if needsCode { needsCode = false; code = "" }
            self.error = error.localizedDescription
        }
    }
}
