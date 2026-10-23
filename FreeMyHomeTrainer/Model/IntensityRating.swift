import Foundation

/// Note d'intensité de 1 à 5 (par demi-points), plus parlante que TSS / IF.
///
/// Elle repose sur l'intensité (IF = puissance normalisée / FTP), via une courbe qui monte de
/// plus en plus vite à l'approche de la FTP, puis tient compte de la durée : une sortie de plus
/// d'une heure est plus dure (jusqu'à +0,75), une séance de moins de 20 minutes un peu moins.
///
/// Repères (FTP 245 W) : 45' à 170 W → 1,5 · endurance 1 h → 1,5 · tempo 2x20' → 2 ·
/// sweet spot 3x10' → 2,5 · VO2 / seuil 2x20' → 4 · 45' à 250 W → 5.
enum IntensityRating {
    /// Points de la courbe (IF → note), interpolés linéairement.
    private static let curve: [(intensity: Double, rating: Double)] = [
        (0.60, 1.0), (0.70, 1.75), (0.85, 3.5), (0.92, 4.25), (1.00, 4.75), (1.05, 5.0),
    ]

    static func value(intensityFactor: Double, hours: Double) -> Double {
        let durationBonus: Double
        switch hours {
        case ..<(1.0 / 3): durationBonus = -0.5
        case ...1: durationBonus = 0
        default: durationBonus = min(0.6 * log2(hours), 0.75)
        }
        let raw = base(intensityFactor) + durationBonus
        return min(max((raw * 2).rounded() / 2, 1), 5)
    }

    private static func base(_ intensity: Double) -> Double {
        guard let first = curve.first, intensity > first.intensity else { return 1 }
        for (a, b) in zip(curve, curve.dropFirst()) where intensity <= b.intensity {
            return a.rating + (b.rating - a.rating) * (intensity - a.intensity) / (b.intensity - a.intensity)
        }
        return 5
    }

    static func label(_ rating: Double) -> String {
        switch rating {
        case ..<1.5: "Très facile"
        case ..<2.5: "Facile"
        case ..<3.5: "Modérée"
        case ..<4.5: "Difficile"
        default: "Très difficile"
        }
    }

    /// « 3,5 » en français.
    static func formatted(_ rating: Double) -> String {
        let hasHalf = rating.truncatingRemainder(dividingBy: 1) != 0
        return rating.formatted(.number.precision(.fractionLength(hasHalf ? 1 : 0)))
    }
}

extension WorkoutTimeline {
    var intensityRating: Double {
        IntensityRating.value(intensityFactor: intensityFactor, hours: duration / 3600)
    }

    /// Puissance moyenne prévue.
    var averageWatts: Double {
        guard duration > 0 else { return 0 }
        return segments.reduce(0) { $0 + $1.averageWatts * $1.duration } / duration
    }
}

extension ActivityRecord {
    var intensityRating: Double {
        IntensityRating.value(intensityFactor: intensityFactor, hours: timerTime / 3600)
    }
}
