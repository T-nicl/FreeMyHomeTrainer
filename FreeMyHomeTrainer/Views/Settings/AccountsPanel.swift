import AuthenticationServices
import SwiftUI
import WebKit

/// Boutons « Connecter Strava » / « Connecter Garmin ». Une seule connexion suffit :
/// seuls les jetons sont conservés (dans le Trousseau), jamais le mot de passe.
struct AccountsPanel: View {
    /// Version compacte (écran Rouler) : sans les options d'envoi automatique.
    var compact = false

    @Environment(UploadCenter.self) private var uploads
    @Environment(\.webAuthenticationSession) private var webAuth
    @AppStorage(Settings.stravaAutoUploadKey) private var stravaAuto = true
    @AppStorage(Settings.garminAutoUploadKey) private var garminAuto = true

    @State private var stravaBusy = false
    @State private var garminBusy = false
    @State private var showGarminLogin = false
    @State private var error: String?
    @State private var customClientID = ""
    @State private var customClientSecret = ""

    private static let stravaOrange = Color(red: 0.99, green: 0.32, blue: 0.0)
    private static let garminBlue = Color(red: 0.0, green: 0.47, blue: 0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AccountRow(name: "Strava", icon: "figure.outdoor.cycle", tint: Self.stravaOrange,
                       connected: uploads.stravaConnected, detail: uploads.stravaAthlete,
                       busy: stravaBusy, enabled: uploads.strava.hasCredentials,
                       connect: { Task { await connectStrava() } },
                       disconnect: {
                           uploads.strava.disconnect()
                           uploads.refreshAccounts()
                       })
            if !compact, uploads.stravaConnected {
                Toggle("Envoyer automatiquement sur Strava après chaque sortie", isOn: $stravaAuto)
                    .padding(.leading, 4)
            }
            if !uploads.strava.hasCredentials {
                stravaKeysMissing
            }

            AccountRow(name: "Garmin", icon: "applewatch", tint: Self.garminBlue,
                       connected: uploads.garminConnected, detail: nil,
                       busy: garminBusy, enabled: true,
                       connect: { showGarminLogin = true },
                       disconnect: {
                           uploads.garmin.disconnect()
                           uploads.refreshAccounts()
                       })
            if !compact, uploads.garminConnected {
                Toggle("Envoyer automatiquement sur Garmin après chaque sortie", isOn: $garminAuto)
                    .padding(.leading, 4)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showGarminLogin) {
            GarminLoginSheet { ticket in
                showGarminLogin = false
                Task { await connectGarmin(ticket: ticket) }
            }
        }
    }

    @ViewBuilder private var stravaKeysMissing: some View {
        if compact {
            Text("Strava : clés de l'application absentes (voir le README).")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            DisclosureGroup("Clés de l'application Strava (développeur)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cette version a été compilée sans clés Strava. Saisis celles de ton application (strava.com/settings/api).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("Client ID", text: $customClientID)
                    SecureField("Client Secret", text: $customClientSecret)
                    Button("Enregistrer") {
                        uploads.strava.clientID = customClientID
                        uploads.strava.clientSecret = customClientSecret
                        uploads.refreshAccounts()
                    }
                    .disabled(customClientID.isEmpty || customClientSecret.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 4)
            }
            .font(.callout)
        }
    }

    private func connectStrava() async {
        stravaBusy = true
        error = nil
        defer { stravaBusy = false }
        do {
            let callback = try await webAuth.authenticate(using: try uploads.strava.authorizationURL(),
                                                          callbackURLScheme: StravaClient.callbackScheme,
                                                          preferredBrowserSession: .ephemeral)
            try await uploads.strava.completeAuthorization(callback: callback)
            uploads.refreshAccounts()
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // Fenêtre fermée par l'utilisateur.
        } catch {
            self.error = "Strava : \(error.localizedDescription)"
        }
    }

    private func connectGarmin(ticket: String) async {
        garminBusy = true
        error = nil
        defer { garminBusy = false }
        do {
            try await uploads.garmin.connect(ticket: ticket)
            uploads.refreshAccounts()
        } catch {
            self.error = "Garmin : \(error.localizedDescription)"
        }
    }
}

private struct AccountRow: View {
    let name: String
    let icon: String
    let tint: Color
    let connected: Bool
    let detail: String?
    let busy: Bool
    let enabled: Bool
    let connect: () -> Void
    let disconnect: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                if connected {
                    Label(detail ?? "Connecté", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Text("Non connecté").font(.caption).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if busy {
                ProgressView().controlSize(.small)
            } else if connected {
                Button("Déconnecter", action: disconnect).fixedSize()
            } else {
                Button("Connecter \(name)", action: connect)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .fixedSize()
                    .disabled(!enabled)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
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
