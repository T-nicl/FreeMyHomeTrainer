import Foundation

/// Vitesses virtuelles (sortie libre) : le trainer garde son pignon unique (Zwift Cog), et l'app
/// simule un développement. La puissance demandée au trainer en ERG est celle d'un vélo roulant
/// sur le plat à la vitesse que donnerait la cadence sur ce développement.
struct VirtualGearbox: Sendable {
    /// 24 développements en progression géométrique, de l'équivalent d'un 34 × 34 (1,0) à celui
    /// d'un 53 × 11 (≈ 4,82) : pas de vraies combinaisons plateau / pignon, des écarts réguliers.
    static let ratios: [Double] = (0..<24).map { 1.0 * pow(53.0 / 11, Double($0) / 23) }
    /// Circonférence d'une roue de route 700 × 25c (m).
    static let wheelCircumference = 2.105
    /// Vitesse de départ : ≈ 50 × 17, ≈ 200 W à 90 rpm pour 70 kg.
    static let defaultGear = 17
    /// Cadence retenue au plus : au-delà, c'est un paquet erroné du capteur, pas le cycliste.
    static let maxCadence = 150.0
    /// Puissance demandée au plus en sortie libre.
    static let maxPower = 1_000
    /// Hausse maximale de la consigne, par seconde (enchaînement de vitesses, pic de cadence).
    static let maxRampPerSecond = 150.0

    /// Vitesse engagée, de 1 (la plus facile) à 24.
    private(set) var gear = VirtualGearbox.defaultGear

    var ratio: Double { Self.ratios[gear - 1] }

    mutating func shift(by delta: Int) {
        gear = min(max(gear + delta, 1), Self.ratios.count)
    }

    /// Vitesse sur route (m/s) pour une cadence (rpm) sur ce développement. Cadence illisible : 0.
    func speed(cadence: Double) -> Double {
        let rpm = cadence.isFinite ? min(max(cadence, 0), Self.maxCadence) : 0
        return rpm / 60 * ratio * Self.wheelCircumference
    }

    /// Puissance (W) à imposer au trainer pour cette cadence ; 0 à l'arrêt, `maxPower` au plus.
    func power(cadence: Double, bike: VirtualBike) -> Int {
        Int(safe: min(bike.steadyPower(speed: speed(cadence: cadence)), Double(Self.maxPower)))
    }
}
