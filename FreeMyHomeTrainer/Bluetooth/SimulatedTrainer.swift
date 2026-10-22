import Foundation

/// Trainer virtuel : suit la consigne ERG avec un peu d'inertie et de bruit,
/// pour développer et tester l'app sans home trainer.
@MainActor
final class SimulatedTrainer {
    var targetPower: Int? = 120

    private let onData: (IndoorBikeData) -> Void
    private var timer: Timer?
    private var power = 0.0
    private var heartRate = 95.0
    private var distance = 0.0

    init(onData: @escaping (IndoorBikeData) -> Void) {
        self.onData = onData
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let goal = Double(targetPower ?? 150)
        power += (goal - power) * 0.35 + Double.random(in: -6...6)
        power = max(power, 0)
        // La FC tend lentement vers une valeur liée à la puissance.
        heartRate += (90 + power * 0.32 - heartRate) * 0.04
        let speedKmh = 3.6 * pow(power / 0.27, 1.0 / 3.0) / 1.6
        distance += speedKmh / 3.6
        onData(IndoorBikeData(speedKmh: speedKmh,
                              cadence: 88 + Double.random(in: -3...3),
                              totalDistance: Int(distance),
                              power: Int(power.rounded()),
                              heartRate: Int(heartRate.rounded())))
    }
}
