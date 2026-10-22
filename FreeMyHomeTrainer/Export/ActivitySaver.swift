import Foundation
import SwiftData

enum ActivitySaver {
    /// Crée l'activité (base locale + fichier .FIT) à partir d'une séance terminée.
    /// Renvoie nil si rien n'a été enregistré (séance arrêtée avant de pédaler).
    @MainActor
    static func save(engine: WorkoutEngine, context: ModelContext, endDate: Date = Date()) throws -> ActivityRecord? {
        guard let start = engine.startDate, !engine.samples.isEmpty else { return nil }
        let name = engine.workout?.name ?? "Sortie libre"
        let record = ActivityRecord(name: name, startDate: start, ftp: engine.ftp)
        let metrics = ActivityMetrics(samples: engine.samples, ftp: engine.ftp)

        record.timerTime = engine.elapsed
        record.elapsedTime = endDate.timeIntervalSince(start)
        record.distance = metrics.distance
        record.avgPower = metrics.avgPower
        record.maxPower = metrics.maxPower
        record.normalizedPower = metrics.normalizedPower
        record.tss = metrics.tss
        record.intensityFactor = metrics.intensityFactor
        record.avgHeartRate = metrics.avgHeartRate
        record.maxHeartRate = metrics.maxHeartRate
        record.avgCadence = metrics.avgCadence
        record.kilojoules = metrics.kilojoules
        record.samples = engine.samples
        record.laps = engine.laps

        let fit = FITEncoder.encode(FITActivity(startDate: start, endDate: endDate, ftp: engine.ftp,
                                                samples: engine.samples, laps: engine.laps))
        let fileName = "\(record.id.uuidString).fit"
        try fit.write(to: Storage.activitiesDirectory.appendingPathComponent(fileName), options: .atomic)
        record.fitFileName = fileName

        context.insert(record)
        try context.save()
        return record
    }

    /// Nom de fichier lisible pour un export manuel.
    static func exportFileName(for record: ActivityRecord) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let safeName = record.name.replacingOccurrences(of: "/", with: "-")
        return "\(f.string(from: record.startDate)) \(safeName).fit"
    }
}
