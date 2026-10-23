import Foundation
import Testing
@testable import FreeMyHomeTrainer

/// Vitesses virtuelles en sortie libre : l'app calcule la puissance d'un vélo sur le plat
/// (cadence × développement) et le trainer la tient en ERG.
@MainActor
struct VirtualGearsTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let bike = VirtualBike(riderMass: 70)

    @Test func gearsGoFromEasyToHard() {
        let ratios = VirtualGearbox.ratios
        #expect(ratios.count == 24)
        #expect(abs(ratios.first! - 1.0) < 0.01)                  // 34 × 34
        #expect(abs(ratios.last! - 53.0 / 11) < 0.01)              // 53 × 11
        #expect(zip(ratios, ratios.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func powerGrowsWithGearAndCadence() {
        var box = VirtualGearbox()
        let p90 = box.power(cadence: 90, bike: bike)
        #expect(box.power(cadence: 100, bike: bike) > p90)
        box.shift(by: 1)
        #expect(box.power(cadence: 90, bike: bike) > p90)
        #expect(box.power(cadence: 0, bike: bike) == 0)            // roue arrêtée : aucune résistance
    }

    /// Vitesse de départ : ≈ 50 × 17, ≈ 34 km/h et ≈ 200 W à 90 rpm pour 70 kg (cf. VirtualBike).
    @Test func defaultGearIsCalibrated() {
        let box = VirtualGearbox()
        #expect(box.gear == 17)
        #expect(abs(box.speed(cadence: 90) * 3.6 - 34) < 1)
        #expect(abs(box.power(cadence: 90, bike: bike) - 198) <= 10)
    }

    @Test func shiftingIsBounded() {
        var box = VirtualGearbox()
        box.shift(by: -100)
        #expect(box.gear == 1)
        box.shift(by: 100)
        #expect(box.gear == VirtualGearbox.ratios.count)
    }

    // MARK: - Moteur

    func freeRide(_ source: MockSource) -> WorkoutEngine {
        WorkoutEngine(workout: nil, ftp: 245, riderWeight: 70, source: source)
    }

    @Test func freeRideSendsTheGearPowerInERG() {
        let source = MockSource()                                  // cadence 90
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        #expect(e.gear == 17)
        #expect(source.grades.isEmpty)                             // plus de mode pente en sortie libre
        let expected = VirtualGearbox().power(cadence: 90, bike: VirtualBike(riderMass: 70))
        #expect(source.targets.last == expected)
        #expect(e.targetWatts == nil)                              // pas de « cible » ni d'« Accélère »
    }

    @Test func shiftingSendsTheNewPowerAtOnce() {
        let source = MockSource()
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        let before = source.targets.last ?? 0
        e.shift(by: 1, now: t0.addingTimeInterval(0.2))
        #expect(e.gear == 18)
        #expect((source.targets.last ?? 0) > before)
    }

    @Test func cadenceChangesFollowWithoutFlooding() {
        let source = MockSource()
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        let sent = source.targets.count
        source.cadence = 90.4                                      // écart < 5 W : rien de renvoyé
        e.tick(now: t0.addingTimeInterval(1))
        #expect(source.targets.count == sent)
        source.cadence = 100
        e.tick(now: t0.addingTimeInterval(2))
        #expect(source.targets.count == sent + 1)
        #expect(source.targets.last! > source.targets[sent - 1])
    }

    @Test func gearsAreOnlyForFreeRides() {
        let source = MockSource()
        let e = WorkoutEngine(workout: Workout.samples[0], ftp: 245, source: source)
        e.start(at: t0, autoTick: false)
        #expect(e.gear == nil)
        let sent = source.targets
        e.shift(by: 1, now: t0)
        #expect(source.targets == sent)
    }

    @Test func finishingAFreeRideReleasesTheTrainer() {
        let source = MockSource()
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        e.finish(now: t0.addingTimeInterval(5))
        #expect(source.grades == [0])                              // plus de consigne ERG après l'arrêt
    }

    @Test func gearPowerIsResentWhenTrainerRegainsControl() {
        let source = MockSource()
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        let sent = source.targets.count
        source.controlGeneration += 1
        e.tick(now: t0.addingTimeInterval(1))
        #expect(source.targets.count == sent + 1)
        #expect(source.grades.isEmpty)
    }

    // Relecture : en pause manuelle, le trainer ne doit pas rester sur ≈ 200 W à l'arrêt.
    @Test func manualPauseReleasesAndResumeRestores() {
        let source = MockSource()
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        let riding = source.targets.last!
        e.togglePause(now: t0.addingTimeInterval(1))
        #expect(source.targets.last == 0)
        e.shift(by: 1, now: t0.addingTimeInterval(2))             // en pause : rien n'est envoyé
        #expect(source.targets.last == 0)
        #expect(e.gear == 18)
        e.togglePause(now: t0.addingTimeInterval(3))
        #expect((source.targets.last ?? 0) > riding)               // reprise : nouvelle vitesse
    }

    // Relecture : un pic de cadence (paquet erroné) ne doit pas demander des milliers de watts.
    @Test func cadenceSpikeIsBounded() {
        let source = MockSource()
        source.cadence = 250
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        #expect((source.targets.last ?? 0) <= VirtualGearbox.maxPower)
        source.cadence = .nan
        e.tick(now: t0.addingTimeInterval(1))
        e.tick(now: t0.addingTimeInterval(3))
        #expect(source.targets.last == 0)                          // cadence illisible : 0 rpm
    }

    // Relecture : enchaîner les ↑ ne fait pas bondir la consigne (≤ 150 W de plus par seconde).
    @Test func rapidUpshiftsAreRateLimited() {
        let source = MockSource()
        let e = freeRide(source)
        e.start(at: t0, autoTick: false)
        let start = source.targets.last!
        for i in 1...7 { e.shift(by: 1, now: t0.addingTimeInterval(1 + Double(i) * 0.1)) }
        #expect(e.gear == 24)
        #expect(source.targets.last! <= start + Int(VirtualGearbox.maxRampPerSecond * 1.8))
        // La consigne rejoint ensuite la bonne valeur, par paliers.
        for i in 2...10 { e.tick(now: t0.addingTimeInterval(Double(i))) }
        let box = { var b = VirtualGearbox(); b.shift(by: 7); return b }()
        #expect(source.targets.last == box.power(cadence: 90, bike: VirtualBike(riderMass: 70)))
    }
}

