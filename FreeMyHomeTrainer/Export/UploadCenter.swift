import Foundation
import Observation
import SwiftData

/// Coordonne l'envoi des activités vers Garmin Connect et met à jour leur état.
/// Strava est alimenté par Garmin (synchronisation Garmin → Strava réglée dans Garmin Connect).
@MainActor
@Observable
final class UploadCenter {
    @ObservationIgnored let garmin = GarminClient()

    /// Recopie observable de l'état du compte (les jetons vivent dans le Trousseau).
    private(set) var garminConnected = false

    init() { refreshAccounts() }

    func refreshAccounts() {
        garminConnected = garmin.isConnected
    }

    /// Envoi automatique après une sortie, selon les réglages.
    func uploadAfterRide(_ record: ActivityRecord, context: ModelContext) {
        let auto = UserDefaults.standard.bool(forKey: Settings.garminAutoUploadKey)   // désactivé par défaut
        guard garminConnected, auto else { return }
        record.garminStatus = .pending
        Task { await uploadToGarmin(record, context: context) }
    }

    /// Au lancement : un envoi resté « en attente » ou « en cours » a été interrompu (app
    /// quittée pendant l'envoi). On le marque en échec pour qu'il puisse être renvoyé.
    static func recoverInterruptedUploads(context: ModelContext) {
        let stuck = [UploadStatus.pending.rawValue, UploadStatus.uploading.rawValue]
        let descriptor = FetchDescriptor<ActivityRecord>(predicate: #Predicate { stuck.contains($0.garminStatusRaw) })
        guard let records = try? context.fetch(descriptor), !records.isEmpty else { return }
        for record in records {
            record.garminStatus = .failed
            record.lastUploadError = "Garmin : envoi interrompu (app fermée pendant l'envoi). Tu peux le renvoyer."
        }
        try? context.save()
    }

    @ObservationIgnored private var didRecover = false

    /// Une seule fois par lancement (l'app n'a qu'un centre d'envoi) : ouvrir une nouvelle
    /// fenêtre (⌘N) ne doit pas marquer en échec un envoi réellement en cours.
    func recoverInterruptedUploadsOnce(context: ModelContext) {
        guard !didRecover else { return }
        didRecover = true
        Self.recoverInterruptedUploads(context: context)
    }

    func uploadToGarmin(_ record: ActivityRecord, context: ModelContext) async {
        // Déjà en cours (double clic sur « Renvoyer ») : un seul envoi à la fois.
        guard record.garminStatus != .uploading else { return }
        guard let fit = record.fitFileURL.flatMap({ try? Data(contentsOf: $0) }) else {
            return fail(record, "Fichier .FIT introuvable", context)
        }
        record.garminStatus = .uploading
        do {
            try await garmin.upload(fit: fit, fileName: ActivitySaver.exportFileName(for: record))
            // La sortie a pu être supprimée pendant l'envoi : ne plus toucher à la fiche.
            guard !record.isDeleted, record.modelContext != nil else { return }
            record.garminStatus = .done
            record.lastUploadError = nil
        } catch {
            return fail(record, error.localizedDescription, context)
        }
        try? context.save()
    }

    private func fail(_ record: ActivityRecord, _ message: String, _ context: ModelContext) {
        refreshAccounts()          // une session expirée déconnecte le compte
        guard !record.isDeleted, record.modelContext != nil else { return }
        record.garminStatus = .failed
        record.lastUploadError = "Garmin : \(message)"
        try? context.save()
    }
}
