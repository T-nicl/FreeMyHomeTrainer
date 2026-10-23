import Foundation
import SwiftData

/// Séance enregistrée dans la bibliothèque. Le contenu est stocké en JSON (même format
/// que celui qu'un LLM produira plus tard).
@Model
final class SavedWorkout {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var payload: Data = Data()
    /// Position choisie par l'utilisateur dans la liste des séances (glisser pour réordonner).
    var sortOrder: Int = 0

    init(_ workout: Workout) {
        self.name = workout.name
        self.payload = (try? workout.jsonData()) ?? Data()
    }

    var workout: Workout {
        // Ramenée dans les limites : une donnée enregistrée ne doit jamais figer ou planter l'app.
        get { ((try? Workout.from(json: payload)) ?? Workout(name: name)).sanitized() }
        set {
            name = newValue.name
            payload = (try? newValue.jsonData()) ?? payload
            updatedAt = Date()
        }
    }
}

/// Un échantillon enregistré à 1 Hz.
struct Sample: Codable, Hashable, Sendable {
    var timestamp: Date
    /// Temps réellement roulé (hors pauses), en secondes.
    var elapsed: TimeInterval
    /// Position dans le déroulé de la séance (différente d'`elapsed` après un intervalle sauté).
    var position: TimeInterval? = nil
    var power: Int?
    var cadence: Int?
    var heartRate: Int?
    /// Vitesse virtuelle en m/s.
    var speed: Double?
    /// Distance cumulée en mètres.
    var distance: Double
    var target: Int?
}

/// Un tour (lap) : un segment de la séance.
struct Lap: Codable, Hashable, Sendable {
    var startTime: Date
    var endTime: Date
    var timerTime: TimeInterval
    /// Indices [début, fin) dans le tableau d'échantillons.
    var sampleRange: Range<Int>
}

enum UploadStatus: String, Codable, Sendable {
    case none, pending, uploading, done, failed
}

@Model
final class ActivityRecord {
    var id: UUID = UUID()
    var startDate: Date = Date()
    var name: String = ""
    var ftp: Int = 200
    var timerTime: TimeInterval = 0
    var elapsedTime: TimeInterval = 0
    var distance: Double = 0
    var avgPower: Int = 0
    var maxPower: Int = 0
    var normalizedPower: Int = 0
    var tss: Double = 0
    var intensityFactor: Double = 0
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var avgCadence: Int?
    var kilojoules: Double = 0

    @Attribute(.externalStorage) var samplesData: Data = Data()
    var lapsData: Data = Data()
    var fitFileName: String?

    var garminStatusRaw: String = UploadStatus.none.rawValue
    var lastUploadError: String?

    init(name: String, startDate: Date, ftp: Int) {
        self.name = name
        self.startDate = startDate
        self.ftp = ftp
    }

    var samples: [Sample] {
        get { (try? JSONDecoder().decode([Sample].self, from: samplesData)) ?? [] }
        set { samplesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var laps: [Lap] {
        get { (try? JSONDecoder().decode([Lap].self, from: lapsData)) ?? [] }
        set { lapsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    var garminStatus: UploadStatus {
        get { UploadStatus(rawValue: garminStatusRaw) ?? .none }
        set { garminStatusRaw = newValue.rawValue }
    }

    var fitFileURL: URL? { fitFileName.map { Storage.activitiesDirectory.appendingPathComponent($0) } }
}

enum Storage {
    static var activitiesDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FreeMyHomeTrainer/Activities", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
