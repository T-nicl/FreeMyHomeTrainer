import Foundation

/// Vélo de route virtuel sur le plat, sans vent : convertit la puissance en vitesse.
/// Modèle physique classique (résistance au roulement + traînée aérodynamique + inertie),
/// réglé pour un bon vélo de route roulé « aux cocottes » : ≈ 35 km/h à 200 W pour 70 kg.
struct VirtualBike: Sendable {
    var riderMass: Double
    var bikeMass = 8.0
    /// Coefficient de roulement : pneus route de bonne qualité sur bon bitume.
    var rollingResistance = 0.004
    /// Surface frontale × coefficient de traînée (m²), mains sur les cocottes.
    var dragArea = 0.32
    var airDensity = 1.225
    /// Rendement de la transmission.
    var drivetrainEfficiency = 0.975

    /// Vitesse en m/s.
    private(set) var speed = 0.0

    init(riderMass: Double) {
        self.riderMass = min(max(riderMass, 30), 200)
    }

    private var totalMass: Double { riderMass + bikeMass }

    private func resistance(at v: Double) -> Double {
        rollingResistance * totalMass * 9.81 + 0.5 * airDensity * dragArea * v * v
    }

    /// Fait avancer le vélo de `dt` secondes avec la puissance donnée (W).
    mutating func step(power: Double, dt: TimeInterval) {
        var t = 0.0
        while t < dt {
            let h = min(0.25, dt - t)
            // Force motrice P/v, bornée à basse vitesse pour un démarrage réaliste.
            let drive = max(power, 0) * drivetrainEfficiency / max(speed, 1)
            speed = max(speed + (drive - resistance(at: speed)) / totalMass * h, 0)
            t += h
        }
    }

    /// Arrêt immédiat (pause).
    mutating func stop() { speed = 0 }

    /// Puissance (W) à fournir pour rouler à vitesse constante `speed` (m/s).
    func steadyPower(speed: Double) -> Double {
        let v = max(speed, 0)
        return resistance(at: v) * v / drivetrainEfficiency
    }

    /// Vitesse stabilisée (m/s) pour une puissance donnée.
    func steadySpeed(power: Double) -> Double {
        let p = max(power, 0) * drivetrainEfficiency
        var lo = 0.0, hi = 30.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            if resistance(at: mid) * mid < p { lo = mid } else { hi = mid }
        }
        return lo
    }
}
