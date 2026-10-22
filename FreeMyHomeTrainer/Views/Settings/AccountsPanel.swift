import SwiftUI
import WebKit

/// Bouton « Connecter Garmin » : une seule connexion suffit, seuls les jetons sont conservés
/// (dans le Trousseau), jamais le mot de passe. Strava est alimenté par Garmin Connect.
struct AccountsPanel: View {
    /// Version compacte (écran Rouler) : sans les options ni l'aide Strava détaillée.
    var compact = false

    @Environment(UploadCenter.self) private var uploads
    @AppStorage(Settings.garminAutoUploadKey) private var garminAuto = true

    @State private var busy = false
    @State private var showLogin = false
    @State private var error: String?

    private static let garminBlue = Color(red: 0.0, green: 0.47, blue: 0.75)

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
                if busy {
                    ProgressView().controlSize(.small)
                } else if uploads.garminConnected {
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

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showLogin) {
            GarminLoginSheet { ticket in
                showLogin = false
                Task { await connect(ticket: ticket) }
            }
        }
    }

    private func connect(ticket: String) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await uploads.garmin.connect(ticket: ticket)
            uploads.refreshAccounts()
        } catch {
            self.error = "Garmin : \(error.localizedDescription)"
        }
    }
}

// MARK: - Connexion Garmin

/// Affiche la page de connexion officielle de Garmin et récupère le ticket SSO.
struct GarminLoginSheet: View {
    let onTicket: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Connexion à Garmin Connect").font(.headline)
                Spacer()
                Button("Annuler") { dismiss() }
            }
            .padding(12)
            Divider()
            GarminWebView(onTicket: onTicket)
            Divider()
            Text("Tu te connectes sur la page de Garmin : l'app ne voit pas ton mot de passe et ne garde qu'un jeton. Envoi non officiel, qui peut cesser de fonctionner si Garmin change sa connexion.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
        .frame(width: 520, height: 680)
    }
}

private struct GarminWebView: NSViewRepresentable {
    let onTicket: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTicket: onTicket) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // aucun cookie conservé
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: GarminClient.loginURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onTicket: (String) -> Void
        private var delivered = false

        init(onTicket: @escaping (String) -> Void) { self.onTicket = onTicket }

        private func deliver(_ ticket: String) {
            guard !delivered else { return }
            delivered = true
            onTicket(ticket)
        }

        // La page de succès redirige vers …/sso/embed?ticket=ST-… : on l'intercepte.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if let url = action.request.url?.absoluteString, url.contains("/sso/embed"),
               let ticket = GarminClient.ticket(in: url) {
                deliver(ticket)
                return .cancel
            }
            return .allow
        }

        // Filet de sécurité : le ticket peut aussi figurer dans le HTML de la page « Success ».
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                guard let html = result as? String, let ticket = GarminClient.ticket(in: html) else { return }
                MainActor.assumeIsolated { self?.deliver(ticket) }
            }
        }
    }
}
