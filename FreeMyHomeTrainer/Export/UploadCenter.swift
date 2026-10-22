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

    func uploadToGarmin(_ record: ActivityRecord, context: ModelContext) async {
        guard let fit = record.fitFileURL.flatMap({ try? Data(contentsOf: $0) }) else {
            return fail(record, "Fichier .FIT introuvable", context)
        }
        record.garminStatus = .uploading
        do {
            try await garmin.upload(fit: fit, fileName: ActivitySaver.exportFileName(for: record))
            record.garminStatus = .done
            record.lastUploadError = nil
        } catch {
            return fail(record, error.localizedDescription, context)
        }
        try? context.save()
    }

    private func fail(_ record: ActivityRecord, _ message: String, _ context: ModelContext) {
        record.garminStatus = .failed
        record.lastUploadError = "Garmin : \(message)"
        try? context.save()
    }
}
