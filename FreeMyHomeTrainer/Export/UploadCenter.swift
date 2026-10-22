import Foundation
import Observation
import SwiftData

/// Coordonne les envois vers Strava et Garmin et met à jour l'état des activités.
@MainActor
@Observable
final class UploadCenter {
    @ObservationIgnored let strava = StravaClient()
    @ObservationIgnored let garmin = GarminClient()

    /// Recopie observable de l'état des comptes (les jetons vivent dans le Trousseau).
    private(set) var stravaConnected = false
    private(set) var stravaAthlete: String?
    private(set) var garminConnected = false

    init() { refreshAccounts() }

    func refreshAccounts() {
        stravaConnected = strava.isConnected
        stravaAthlete = strava.athleteName
        garminConnected = garmin.isConnected
    }

    /// Envois automatiques après une sortie, selon les réglages.
    func uploadAfterRide(_ record: ActivityRecord, context: ModelContext) {
        let defaults = UserDefaults.standard
        if stravaConnected, defaults.object(forKey: Settings.stravaAutoUploadKey) as? Bool ?? true {
            record.stravaStatus = .pending
            Task { await uploadToStrava(record, context: context) }
        }
        if garminConnected, defaults.object(forKey: Settings.garminAutoUploadKey) as? Bool ?? true {
            record.garminStatus = .pending
            Task { await uploadToGarmin(record, context: context) }
        }
    }

    func uploadToStrava(_ record: ActivityRecord, context: ModelContext) async {
        guard let fit = fitData(for: record) else { return fail(record, strava: true, "Fichier .FIT introuvable", context) }
        record.stravaStatus = .uploading
        do {
            let id = try await strava.upload(fit: fit, name: record.name, externalID: record.id.uuidString)
            record.stravaActivityID = id
            record.stravaStatus = .done
            record.lastUploadError = nil
        } catch {
            fail(record, strava: true, error.localizedDescription, context)
        }
        try? context.save()
    }

    func uploadToGarmin(_ record: ActivityRecord, context: ModelContext) async {
        guard let fit = fitData(for: record) else { return fail(record, strava: false, "Fichier .FIT introuvable", context) }
        record.garminStatus = .uploading
        do {
            try await garmin.upload(fit: fit, fileName: ActivitySaver.exportFileName(for: record))
            record.garminStatus = .done
            record.lastUploadError = nil
        } catch {
            fail(record, strava: false, error.localizedDescription, context)
        }
        try? context.save()
    }

    private func fitData(for record: ActivityRecord) -> Data? {
        record.fitFileURL.flatMap { try? Data(contentsOf: $0) }
    }

    private func fail(_ record: ActivityRecord, strava: Bool, _ message: String, _ context: ModelContext) {
        if strava { record.stravaStatus = .failed } else { record.garminStatus = .failed }
        record.lastUploadError = "\(strava ? "Strava" : "Garmin") : \(message)"
        try? context.save()
    }
}
