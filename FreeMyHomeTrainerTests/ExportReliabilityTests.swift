import Foundation
import SwiftData
import Testing
@testable import FreeMyHomeTrainer

/// Lot 3 des relectures ECC : fiabilité du fichier FIT et de l'envoi Garmin.
@MainActor
struct ExportReliabilityTests {
    let start = Date(timeIntervalSince1970: 1_700_000_000)   // 14 nov. 2023, hiver à New York (UTC−5)

    func samples(timestamps: [TimeInterval], elapsed: [TimeInterval]) -> [Sample] {
        zip(timestamps, elapsed).map { t, e in
            Sample(timestamp: start.addingTimeInterval(t), elapsed: e, power: 150, cadence: 90,
                   heartRate: 140, speed: 9, distance: e * 9, target: 150)
        }
    }

    func events(_ s: [Sample], timeZone: TimeZone = .current) throws -> [FITTestDecoder.Message] {
        let fit = FITEncoder.encode(FITActivity(startDate: start, endDate: start.addingTimeInterval(60), ftp: 250,
                                                samples: s,
                                                laps: [Lap(startTime: start, endTime: start.addingTimeInterval(60),
                                                           timerTime: 10, sampleRange: 0..<s.count)],
                                                timeZone: timeZone))
        return try FITTestDecoder.decode(fit)
    }

    // 1. Un tic d'horloge un peu en retard n'est pas une pause ; une vraie pause en est une.
    @Test func timerJitterIsNotAPause() throws {
        let jitter = samples(timestamps: [1, 2, 3.6, 4.6, 5.6], elapsed: [1, 2, 3.6, 4.6, 5.6])
        #expect(try events(jitter).filter { $0.global == 21 }.count == 2)       // start + stop

        // « Intervalle suivant » peut perdre jusqu'à ~1,3 s de temps roulé : pas une pause non plus.
        let skip = samples(timestamps: [1, 2, 4.3, 5.3], elapsed: [1, 2, 3, 4])
        #expect(try events(skip).filter { $0.global == 21 }.count == 2)

        let paused = samples(timestamps: [1, 2, 33, 34], elapsed: [1, 2, 3, 4])  // 30 s de pause
        #expect(try events(paused).filter { $0.global == 21 }.count == 4)       // + stop/start
    }

    // 2. Heure locale juste à l'ouest de Greenwich.
    @Test func localTimestampWestOfGreenwich() throws {
        let s = samples(timestamps: [1, 2, 3], elapsed: [1, 2, 3])
        let messages = try events(s, timeZone: try #require(TimeZone(identifier: "America/New_York")))
        let activity = try #require(messages.first { $0.global == 34 })
        let end = try #require(activity.fields[253])
        #expect(activity.fields[5] == end - 5 * 3600)
    }

    // 3. Un envoi interrompu (app quittée) ne reste pas bloqué « en cours ».
    @Test func interruptedUploadsAreRecoveredAtLaunch() throws {
        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let stuck = ActivityRecord(name: "a", startDate: start, ftp: 250)
        stuck.garminStatus = .uploading
        let queued = ActivityRecord(name: "b", startDate: start, ftp: 250)
        queued.garminStatus = .pending
        let done = ActivityRecord(name: "c", startDate: start, ftp: 250)
        done.garminStatus = .done
        [stuck, queued, done].forEach(container.mainContext.insert)

        let uploads = UploadCenter()
        uploads.recoverInterruptedUploadsOnce(context: container.mainContext)
        #expect(stuck.garminStatus == .failed)
        #expect(queued.garminStatus == .failed)
        #expect(stuck.lastUploadError?.contains("interrompu") == true)
        #expect(done.garminStatus == .done)

        // Une nouvelle fenêtre (⌘N) ne doit pas marquer en échec un envoi réellement en cours.
        let live = ActivityRecord(name: "d", startDate: start, ftp: 250)
        live.garminStatus = .uploading
        container.mainContext.insert(live)
        uploads.recoverInterruptedUploadsOnce(context: container.mainContext)
        #expect(live.garminStatus == .uploading)
    }

    // Double clic sur « Renvoyer » : un seul envoi à la fois pour une même sortie.
    @Test func noConcurrentUploadOfTheSameRide() async throws {
        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let record = ActivityRecord(name: "a", startDate: start, ftp: 250)
        record.garminStatus = .uploading
        container.mainContext.insert(record)
        await UploadCenter().uploadToGarmin(record, context: container.mainContext)
        #expect(record.garminStatus == .uploading)                               // déjà en cours : ignoré
    }

    // 4. Jeton refusé (401) : renouveler puis réessayer une fois ; pas pour les autres erreurs.
    @Test func tokenRefreshPolicy() {
        #expect(GarminClient.shouldRefreshToken(after: HTTPError(status: 401, body: "")))
        #expect(!GarminClient.shouldRefreshToken(after: HTTPError(status: 500, body: "")))
        #expect(!GarminClient.shouldRefreshToken(after: URLError(.notConnectedToInternet)))
    }

    // Le jeton d'accès ne doit jamais suivre une redirection hors de garmin.com.
    @Test func redirectsOutsideGarminAreRefused() {
        #expect(RedirectGuard.isAllowed(URL(string: "https://connectapi.garmin.com/upload-service/upload")))
        #expect(RedirectGuard.isAllowed(URL(string: "https://sso.garmin.com/sso/embed")))
        #expect(!RedirectGuard.isAllowed(URL(string: "https://evil.example.com/garmin.com")))
        #expect(!RedirectGuard.isAllowed(URL(string: "https://notgarmin.com/")))
        #expect(!RedirectGuard.isAllowed(URL(string: "http://connectapi.garmin.com/")))   // pas de HTTP en clair
    }

    // 6. Un nom de séance ne peut pas casser l'en-tête de l'envoi (guillemets, retours à la ligne).
    @Test func multipartFileNameIsEscaped() {
        var body = MultipartBody()
        body.addFile("file", fileName: "a\"b\r\nX-Injected: 1\u{0}\u{7}.fit", mimeType: "application/octet-stream",
                     content: Data([1]))
        let text = String(decoding: body.finalized(), as: UTF8.self)
        #expect(!text.contains("\r\nX-Injected"))
        #expect(!text.contains("a\"b"))
        #expect(!text.contains("\u{0}") && !text.contains("\u{7}"))             // caractères de contrôle
    }

    // 7. Le message d'erreur enregistré ne contient pas la réponse brute du serveur.
    @Test func httpErrorDoesNotExposeResponseBody() {
        let error = HTTPError(status: 401, body: "access_token=SECRET-VALUE")
        #expect(error.localizedDescription.contains("401"))
        #expect(!error.localizedDescription.contains("SECRET"))
    }
}
