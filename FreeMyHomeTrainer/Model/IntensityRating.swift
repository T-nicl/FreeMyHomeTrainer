import Foundation

/// Note d'intensité de 1 à 5 (par demi-points), plus parlante que TSS / IF.
/// Elle combine l'intensité (IF) et la charge totale (TSS), si bien qu'une longue sortie
/// d'endurance peut être aussi « dure » qu'une séance courte et intense.
/// Repères : récupération 1 · endurance 1 h 2 · sweet spot 3 · VO2 max 4 · seuil 2x20' 4,5.
enum IntensityRating {
    static func value(intensityFactor: Double, tss: Double) -> Double {
        let raw = 1 + 7.5 * max(intensityFactor - 0.55, 0) + 0.0075 * max(tss, 0)
        return min(max((raw * 2).rounded() / 2, 1), 5)
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
        IntensityRating.value(intensityFactor: intensityFactor, tss: trainingStressScore)
    }

    /// Puissance moyenne prévue.
    var averageWatts: Double {
        guard duration > 0 else { return 0 }
        return segments.reduce(0) { $0 + $1.averageWatts * $1.duration } / duration
    }
}

extension ActivityRecord {
    var intensityRating: Double {
        IntensityRating.value(intensityFactor: intensityFactor, tss: tss)
    }
}
