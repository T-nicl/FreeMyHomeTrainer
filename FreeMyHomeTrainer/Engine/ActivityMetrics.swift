import Foundation

/// Statistiques calculées à partir des échantillons 1 Hz d'une activité ou d'un tour.
struct ActivityMetrics: Equatable, Sendable {
    var duration: TimeInterval = 0
    var avgPower = 0
    var maxPower = 0
    var normalizedPower = 0
    var intensityFactor = 0.0
    var tss = 0.0
    var kilojoules = 0.0
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    var avgCadence: Int?
    var maxCadence: Int?
    var distance = 0.0

    init() {}

    init(samples: ArraySlice<Sample>, ftp: Int) {
        guard let first = samples.first, let last = samples.last else { return }
        let powers = samples.map { $0.power ?? 0 }
        duration = TimeInterval(samples.count)
        avgPower = Int((Double(powers.reduce(0, +)) / Double(powers.count)).rounded())
        maxPower = powers.max() ?? 0
        kilojoules = Double(powers.reduce(0, +)) / 1000

        // NP : moyenne glissante sur 30 s, puissance 4, moyenne, racine 4.
        if powers.count >= 30 {
            var window = powers.prefix(30).reduce(0, +)
            var sum4 = pow(Double(window) / 30, 4)
            for i in 30..<powers.count {
                window += powers[i] - powers[i - 30]
                sum4 += pow(Double(window) / 30, 4)
            }
            normalizedPower = Int(pow(sum4 / Double(powers.count - 29), 0.25).rounded())
        } else {
            normalizedPower = avgPower
        }
        if ftp > 0 {
            intensityFactor = Double(normalizedPower) / Double(ftp)
            tss = duration / 3600 * intensityFactor * intensityFactor * 100
        }

        let hrs = samples.compactMap(\.heartRate).filter { $0 > 0 }
        if !hrs.isEmpty {
            avgHeartRate = Int((Double(hrs.reduce(0, +)) / Double(hrs.count)).rounded())
            maxHeartRate = hrs.max()
        }
        // Cadence moyenne hors arrêts de pédalage, comme sur les compteurs.
        let cads = samples.compactMap(\.cadence).filter { $0 > 0 }
        if !cads.isEmpty {
            avgCadence = Int((Double(cads.reduce(0, +)) / Double(cads.count)).rounded())
            maxCadence = cads.max()
        }
        // La distance de chaque échantillon est cumulée : on ajoute la seconde du premier.
        distance = last.distance - first.distance + (first.speed ?? 0)
    }

    init(samples: [Sample], ftp: Int) {
        self.init(samples: samples[...], ftp: ftp)
    }
}
