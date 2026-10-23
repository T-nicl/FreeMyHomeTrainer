import Foundation

/// Repère les séances physiquement irréalistes (ex. 3 × 10' à 400 % de la FTP).
///
/// Au-dessus de la FTP, on s'appuie sur le modèle de puissance critique : la durée tenable à une
/// puissance P vaut W' / (P − FTP), avec une réserve anaérobie W' ≈ 82 J par watt de FTP
/// (≈ 20 kJ pour une FTP de 245 W) : ≈ 7' à 120 %, ≈ 80 s à 200 %, ≈ 27 s à 400 %.
/// Un bloc est signalé s'il dure plus d'une fois et demie cette limite. Ce n'est qu'un
/// avertissement : la séance reste enregistrable telle quelle.
enum WorkoutSanity {
    /// Réserve anaérobie, en joules par watt de FTP.
    static let reservePerFTPWatt = 82.0
    /// Marge avant de signaler un bloc (1,5 = 50 % au-delà de la durée tenable estimée).
    static let tolerance = 1.5

    /// Durée tenable estimée (s) à `fraction` de la FTP ; nil si l'effort est tenable longtemps.
    static func sustainableDuration(atFTPFraction fraction: Double) -> TimeInterval? {
        guard fraction > 1.05 else { return nil }
        return reservePerFTPWatt / (fraction - 1)
    }

    /// Avertissements lisibles (au plus un par bloc), vides si la séance paraît réaliste.
    static func warnings(for workout: Workout, ftp: Int) -> [String] {
        guard ftp > 0 else { return [] }
        var out: [String] = []
        for block in workout.blocks.leaves {
            let watts = max(block.target.watts(ftp: ftp),
                            block.kind == .ramp ? block.endTarget.watts(ftp: ftp) : 0)
            let fraction = watts / Double(ftp)
            let what = "\(Format.duration(block.duration)) à \(Int(safe: watts)) W (\(Int(safe: fraction * 100)) % FTP)"

            if watts > 2000 {
                out.append("\(what) : plus de 2 000 W, c'est hors de portée même pour un sprinteur.")
            } else if let limit = sustainableDuration(atFTPFraction: fraction), block.duration > limit * tolerance {
                out.append("\(what) : un tel effort ne se tient qu'environ \(spoken(limit)).")
            } else if fraction >= 0.95, block.duration > 75 * 60 {
                out.append("\(what) : rester au seuil plus d'1 h 15 est quasi impossible.")
            } else if fraction >= 0.85, block.duration > 3 * 3600 {
                out.append("\(what) : plus de 3 h à ce niveau est très peu réaliste.")
            }
        }
        if workout.totalDuration > 6 * 3600 {
            out.append("Séance de \(Format.duration(workout.totalDuration)) : c'est très long pour du home trainer.")
        }
        return out
    }

    /// « 30 s », « 2 min », « 7 min ».
    private static func spoken(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(Int(safe: seconds / 5) * 5, 5)) s" }
        return "\(Int(safe: seconds / 60)) min"
    }
}
