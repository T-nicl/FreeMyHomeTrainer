import Foundation

/// Un segment élémentaire de séance, en watts absolus (FTP déjà appliquée).
struct WorkoutSegment: Hashable, Sendable {
    var start: TimeInterval
    var duration: TimeInterval
    var startWatts: Double
    var endWatts: Double
    /// Pour un segment issu d'une répétition : (numéro 1-based, total).
    var repetition: (index: Int, count: Int)?

    var end: TimeInterval { start + duration }
    var isRamp: Bool { startWatts != endWatts }
    var averageWatts: Double { (startWatts + endWatts) / 2 }

    func watts(at time: TimeInterval) -> Double {
        guard duration > 0 else { return startWatts }
        let progress = min(max((time - start) / duration, 0), 1)
        return startWatts + (endWatts - startWatts) * progress
    }

    var label: String {
        let d = Format.duration(duration)
        let p = isRamp ? "\(Int(safe: startWatts))→\(Int(safe: endWatts)) W"
                       : "\(Int(safe: startWatts)) W"
        return "\(d) @ \(p)"
    }

    static func == (a: Self, b: Self) -> Bool {
        a.start == b.start && a.duration == b.duration && a.startWatts == b.startWatts
            && a.endWatts == b.endWatts && a.repetition?.index == b.repetition?.index
            && a.repetition?.count == b.repetition?.count
    }

    func hash(into h: inout Hasher) {
        h.combine(start); h.combine(duration); h.combine(startWatts); h.combine(endWatts)
    }
}

/// Séance « aplatie » : liste ordonnée de segments contigus.
struct WorkoutTimeline: Sendable {
    let segments: [WorkoutSegment]
    let ftp: Int

    init(workout: Workout, ftp: Int) {
        self.ftp = ftp
        var segments: [WorkoutSegment] = []
        var t: TimeInterval = 0
        Self.flatten(workout.blocks, ftp: ftp, repetition: nil, time: &t, into: &segments)
        self.segments = segments
    }

    private static func flatten(_ blocks: [WorkoutBlock], ftp: Int, repetition: (Int, Int)?,
                                time: inout TimeInterval, into out: inout [WorkoutSegment]) {
        for block in blocks {
            // Filet de sécurité : jamais plus de `maxSegments` segments (mémoire, temps de calcul).
            guard out.count < WorkoutLimits.maxSegments else { return }
            switch block.kind {
            case .steady, .ramp:
                guard block.duration > 0 else { continue }
                let end = block.kind == .ramp ? block.endTarget : block.target
                out.append(WorkoutSegment(start: time, duration: block.duration,
                                          startWatts: block.target.watts(ftp: ftp),
                                          endWatts: end.watts(ftp: ftp),
                                          repetition: repetition))
                time += block.duration
            case .repeats:
                // Une répétition qui ne produit rien est sautée : sans cela, des répétitions vides
                // imbriquées échappaient au plafond de segments et figeaient l'app (50⁶ tours).
                guard block.count > 0, block.producesSegments else { continue }
                for i in 1...block.count where out.count < WorkoutLimits.maxSegments {
                    flatten(block.blocks, ftp: ftp, repetition: (i, block.count), time: &time, into: &out)
                }
            }
        }
    }

    var duration: TimeInterval { segments.last?.end ?? 0 }

    func segmentIndex(at time: TimeInterval) -> Int? {
        guard time >= 0, time < duration else { return nil }
        // Recherche dichotomique : les segments sont triés et contigus.
        var lo = 0, hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = segments[mid]
            if time < s.start { hi = mid - 1 } else if time >= s.end { lo = mid + 1 } else { return mid }
        }
        return nil
    }

    func targetWatts(at time: TimeInterval) -> Double? {
        segmentIndex(at: time).map { segments[$0].watts(at: time) }
    }

    /// Puissance normalisée estimée de la séance (NP ≈ moyenne quartique des cibles).
    var normalizedPower: Double {
        guard duration > 0 else { return 0 }
        var sum = 0.0
        for s in segments {
            // Intégration par pas de 5 s pour les rampes.
            let steps = max(Int(s.duration / 5), 1)
            let dt = s.duration / Double(steps)
            for k in 0..<steps {
                let p = s.watts(at: s.start + (Double(k) + 0.5) * dt)
                sum += pow(p, 4) * dt
            }
        }
        return pow(sum / duration, 0.25)
    }

    var intensityFactor: Double { ftp > 0 ? normalizedPower / Double(ftp) : 0 }

    var trainingStressScore: Double { duration / 3600 * intensityFactor * intensityFactor * 100 }
}

/// Zones de puissance de Coggan.
enum PowerZone: Int, CaseIterable, Sendable {
    case z1 = 1, z2, z3, z4, z5, z6

    init(watts: Double, ftp: Int) {
        let pct = ftp > 0 ? watts / Double(ftp) * 100 : 0
        switch pct {
        case ..<56: self = .z1
        case ..<76: self = .z2
        case ..<91: self = .z3
        case ..<106: self = .z4
        case ..<121: self = .z5
        default: self = .z6
        }
    }

    var name: String {
        switch self {
        case .z1: "Récupération"
        case .z2: "Endurance"
        case .z3: "Tempo"
        case .z4: "Seuil"
        case .z5: "VO2 max"
        case .z6: "Anaérobie"
        }
    }
}

extension Workout {
    /// Une séance sans aucun bloc ne se roule pas : le trainer resterait sans consigne.
    func isRideable(ftp: Int) -> Bool { WorkoutTimeline(workout: self, ftp: ftp).duration > 0 }
}

enum Format {
    /// 3725 → "1:02:05", 600 → "10:00"
    static func clock(_ t: TimeInterval) -> String {
        let s = max(Int(safe: t.rounded(.down)), 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    /// 600 → "10'", 90 → "1'30", 45 → "45\"", 3900 → "1h05"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(Int(safe: t), 0)
        if s >= 3600 { return String(format: "%dh%02d", s / 3600, (s % 3600) / 60) }
        if s < 60 { return "\(s)\"" }
        return s % 60 == 0 ? "\(s / 60)'" : String(format: "%d'%02d", s / 60, s % 60)
    }
}
