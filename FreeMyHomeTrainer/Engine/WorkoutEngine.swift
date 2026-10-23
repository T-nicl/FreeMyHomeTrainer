import Foundation
import Observation

/// Ce dont le moteur a besoin côté capteurs : les mesures et le pilotage du trainer.
@MainActor
protocol RideDataSource: AnyObject {
    var power: Int? { get }
    var cadence: Double? { get }
    var currentHeartRate: Int? { get }
    /// Incrémenté à chaque (re)prise de contrôle du trainer : la consigne doit alors être renvoyée.
    var controlGeneration: Int { get }
    func setTargetPower(_ watts: Int)
    func setGrade(_ percent: Double)
}

extension DeviceManager: RideDataSource {}

/// Déroule une séance : temps, segment courant, consignes ERG, pauses et enregistrement.
@MainActor
@Observable
final class WorkoutEngine {
    enum State: Equatable {
        case ready, running, paused, autoPaused, finished
    }

    enum Cue {
        /// Quelques secondes avant le prochain intervalle.
        case countdown
        /// Début d'un nouvel intervalle.
        case intervalStart
    }

    let workout: Workout?
    let ftp: Int
    let timeline: WorkoutTimeline?

    private(set) var state: State = .ready
    /// Temps réellement roulé, pauses exclues (c'est le temps de la séance enregistrée).
    private(set) var elapsed: TimeInterval = 0
    /// Position dans le déroulé de la séance : avance avec le temps, et saute en avant
    /// quand on passe un intervalle (sans compter ce temps comme roulé).
    private(set) var position: TimeInterval = 0
    /// Vitesse et distance virtuelles (vélo de route sur le plat).
    private(set) var speedKmh = 0.0
    private(set) var distance = 0.0
    private(set) var startDate: Date?
    private(set) var segmentIndex: Int?
    private(set) var targetWatts: Int?
    /// Multiplicateur d'intensité ajusté en cours de séance (±5 %).
    private(set) var intensity = 1.0
    private(set) var samples: [Sample] = []
    private(set) var laps: [Lap] = []
    private(set) var power3s: Int?

    @ObservationIgnored var onCue: ((Cue) -> Void)?

    @ObservationIgnored private let source: RideDataSource
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var lastSentTarget: Int?
    @ObservationIgnored private var lastSentAt: Date?
    @ObservationIgnored private var seenControlGeneration = 0
    @ObservationIgnored private var stoppedPedalingSince: Date?
    @ObservationIgnored private var bike: VirtualBike
    @ObservationIgnored private var recentPowers: [Int] = []
    @ObservationIgnored private var lapStart: (date: Date, elapsed: TimeInterval, sample: Int)?
    @ObservationIgnored private var countdownCuedFor: Int?
    @ObservationIgnored private var timer: Timer?
    /// Empêche la mise en veille de l'écran pendant la séance.
    @ObservationIgnored private var noSleepActivity: NSObjectProtocol?

    /// Secondes sans pédaler avant la pause automatique.
    static let autoPauseDelay: TimeInterval = 3

    init(workout: Workout?, ftp: Int, riderWeight: Double = 75, source: RideDataSource) {
        self.workout = workout
        self.ftp = ftp
        self.source = source
        self.bike = VirtualBike(riderMass: riderWeight)
        self.timeline = workout.map { WorkoutTimeline(workout: $0, ftp: ftp) }
    }

    // MARK: - État dérivé

    var currentSegment: WorkoutSegment? { segmentIndex.flatMap { timeline?.segments[$0] } }

    var nextSegment: WorkoutSegment? {
        guard let i = segmentIndex, let tl = timeline, i + 1 < tl.segments.count else { return nil }
        return tl.segments[i + 1]
    }

    var segmentRemaining: TimeInterval? { currentSegment.map { $0.end - position } }

    var workoutRemaining: TimeInterval? { timeline.map { max($0.duration - position, 0) } }

    var isWorkoutComplete: Bool { timeline.map { position >= $0.duration } ?? false }

    var isActive: Bool { state == .running || state == .paused || state == .autoPaused }

    // MARK: - Commandes

    func start(at now: Date = Date(), autoTick: Bool = true) {
        guard state == .ready else { return }
        state = .running
        startDate = now
        lastTick = now
        lapStart = (now, 0, 0)
        seenControlGeneration = source.controlGeneration
        if timeline == nil {
            source.setGrade(0)   // sortie libre : pas de consigne ERG
        } else {
            updateTarget(now: now, force: true)
        }
        if autoTick {
            noSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Séance en cours")
            timer = RepeatingTimer.schedule(every: 1) { [weak self] in self?.tick(now: Date()) }
        }
    }

    func togglePause() {
        switch state {
        case .running, .autoPaused: state = .paused
        case .paused: state = .running; stoppedPedalingSince = nil
        default: break
        }
    }

    /// Passe directement à l'intervalle suivant (le temps sauté n'est pas compté comme roulé).
    func skipSegment(now: Date = Date()) {
        guard let segment = currentSegment else { return }
        position = segment.end
        tick(now: now, advanceClock: false)
    }

    func adjustIntensity(by delta: Double, now: Date = Date()) {
        intensity = min(max(intensity + delta, 0.5), 1.5)
        updateTarget(now: now, force: true)
    }

    /// Termine la séance (ferme le dernier tour).
    func finish(now: Date = Date()) {
        guard isActive else { return }
        timer?.invalidate()
        timer = nil
        if let noSleepActivity { ProcessInfo.processInfo.endActivity(noSleepActivity) }
        noSleepActivity = nil
        // Arrêt en cours de séance : le trainer ne doit pas rester bloqué sur la consigne ERG.
        if timeline != nil, !isWorkoutComplete { source.setGrade(0) }
        closeLap(now: now)
        state = .finished
    }

    // MARK: - Horloge

    /// Avance la séance. Appelé chaque seconde (ou par les tests avec une date simulée).
    func tick(now: Date, advanceClock: Bool = true) {
        guard isActive, let last = lastTick else { return }
        // Plafonné pour ne pas compter une mise en veille comme du temps de séance.
        let dt = advanceClock ? min(max(now.timeIntervalSince(last), 0), 2) : 0
        lastTick = now

        let power = source.power ?? 0
        recentPowers.append(power)
        if recentPowers.count > 3 { recentPowers.removeFirst() }
        power3s = source.power == nil ? nil : recentPowers.reduce(0, +) / recentPowers.count

        resendTargetIfControlRegained(now: now)
        updateAutoPause(now: now)
        guard state == .running else {
            bike.stop()
            speedKmh = 0
            return
        }

        elapsed += dt
        position += dt
        bike.step(power: Double(power), dt: dt)
        speedKmh = bike.speed * 3.6
        distance += bike.speed * dt

        updateTarget(now: now, force: false)
        if dt > 0 { recordSample(now: now) }
    }

    /// Après une reconnexion ou une prise de contrôle par une autre app, le trainer a perdu la
    /// consigne : on la renvoie immédiatement au lieu d'attendre le prochain changement de palier.
    private func resendTargetIfControlRegained(now: Date) {
        guard source.controlGeneration != seenControlGeneration else { return }
        seenControlGeneration = source.controlGeneration
        lastSentTarget = nil
        if timeline == nil || isWorkoutComplete {
            source.setGrade(0)
        } else {
            updateTarget(now: now, force: true)
        }
    }

    private func updateAutoPause(now: Date) {
        let pedaling = (source.cadence ?? 0) > 0 || (source.power ?? 0) > 0
        switch state {
        case .running where !pedaling:
            let since = stoppedPedalingSince ?? now
            stoppedPedalingSince = since
            if now.timeIntervalSince(since) >= Self.autoPauseDelay { state = .autoPaused }
        case .autoPaused where pedaling:
            state = .running
            stoppedPedalingSince = nil
        case .running:
            stoppedPedalingSince = nil
        default:
            break
        }
    }

    private func updateTarget(now: Date, force: Bool) {
        guard let timeline else { return }
        let index = timeline.segmentIndex(at: position)
        if index != segmentIndex {
            if segmentIndex != nil {
                closeLap(now: now)
                if index != nil { onCue?(.intervalStart) }
            }
            segmentIndex = index
            if index == nil, isWorkoutComplete {
                // Séance terminée : on libère le trainer (pente nulle) en attendant l'arrêt.
                targetWatts = nil
                source.setGrade(0)
                return
            }
        }

        if let remaining = segmentRemaining, remaining <= 4, nextSegment != nil, countdownCuedFor != segmentIndex {
            countdownCuedFor = segmentIndex
            onCue?(.countdown)
        }

        guard let watts = timeline.targetWatts(at: position) else { return }
        let target = Int((watts * intensity).rounded())
        targetWatts = target
        // Envoi au trainer uniquement si la consigne change (au plus une fois par seconde).
        let canSend = force || lastSentAt.map { now.timeIntervalSince($0) >= 1 } ?? true
        if target != lastSentTarget, canSend {
            source.setTargetPower(target)
            lastSentTarget = target
            lastSentAt = now
        }
    }

    private func recordSample(now: Date) {
        samples.append(Sample(timestamp: now,
                              elapsed: elapsed,
                              position: timeline == nil ? nil : position,
                              power: source.power,
                              cadence: source.cadence.map { Int($0.rounded()) },
                              heartRate: source.currentHeartRate,
                              speed: bike.speed,
                              distance: distance,
                              target: targetWatts))
    }

    private func closeLap(now: Date) {
        guard let start = lapStart else { return }
        if samples.count > start.sample {
            laps.append(Lap(startTime: start.date, endTime: now,
                            timerTime: elapsed - start.elapsed,
                            sampleRange: start.sample..<samples.count))
        }
        lapStart = (now, elapsed, samples.count)
    }
}

/// Minuterie répétitive sur le fil principal, inscrite dans les modes « courants » de la boucle
/// d'événements : elle continue pendant un déplacement / redimensionnement de fenêtre ou un menu
/// ouvert (`Timer.scheduledTimer` se fige dans ces cas, ce qui faussait le chrono de la séance).
enum RepeatingTimer {
    @discardableResult
    static func schedule(every interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
