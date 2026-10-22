import Foundation
import Observation

/// Ce dont le moteur a besoin côté capteurs : les mesures et le pilotage du trainer.
@MainActor
protocol RideDataSource: AnyObject {
    var power: Int? { get }
    var cadence: Double? { get }
    var speedKmh: Double? { get }
    var currentHeartRate: Int? { get }
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
    /// Temps de séance, pauses exclues.
    private(set) var elapsed: TimeInterval = 0
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
    @ObservationIgnored private var stoppedPedalingSince: Date?
    @ObservationIgnored private var distance = 0.0
    @ObservationIgnored private var recentPowers: [Int] = []
    @ObservationIgnored private var lapStart: (date: Date, elapsed: TimeInterval, sample: Int)?
    @ObservationIgnored private var countdownCuedFor: Int?
    @ObservationIgnored private var timer: Timer?
    /// Empêche la mise en veille de l'écran pendant la séance.
    @ObservationIgnored private var noSleepActivity: NSObjectProtocol?

    /// Secondes sans pédaler avant la pause automatique.
    static let autoPauseDelay: TimeInterval = 3

    init(workout: Workout?, ftp: Int, source: RideDataSource) {
        self.workout = workout
        self.ftp = ftp
        self.source = source
        self.timeline = workout.map { WorkoutTimeline(workout: $0, ftp: ftp) }
    }

    // MARK: - État dérivé

    var currentSegment: WorkoutSegment? { segmentIndex.flatMap { timeline?.segments[$0] } }

    var nextSegment: WorkoutSegment? {
        guard let i = segmentIndex, let tl = timeline, i + 1 < tl.segments.count else { return nil }
        return tl.segments[i + 1]
    }

    var segmentRemaining: TimeInterval? { currentSegment.map { $0.end - elapsed } }

    var workoutRemaining: TimeInterval? { timeline.map { max($0.duration - elapsed, 0) } }

    var isWorkoutComplete: Bool { timeline.map { elapsed >= $0.duration } ?? false }

    var isActive: Bool { state == .running || state == .paused || state == .autoPaused }

    // MARK: - Commandes

    func start(at now: Date = Date(), autoTick: Bool = true) {
        guard state == .ready else { return }
        state = .running
        startDate = now
        lastTick = now
        lapStart = (now, 0, 0)
        if timeline == nil {
            source.setGrade(0)   // sortie libre : pas de consigne ERG
        } else {
            updateTarget(now: now, force: true)
        }
        if autoTick {
            noSleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Séance en cours")
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(now: Date()) }
            }
        }
    }

    func togglePause() {
        switch state {
        case .running, .autoPaused: state = .paused
        case .paused: state = .running; stoppedPedalingSince = nil
        default: break
        }
    }

    /// Passe directement à l'intervalle suivant.
    func skipSegment(now: Date = Date()) {
        guard let segment = currentSegment else { return }
        elapsed = segment.end
        tick(now: now, advanceClock: false)
    }

    func adjustIntensity(by delta: Double, now: Date = Date()) {
        intensity = min(max(intensity + delta, 0.5), 1.5)
        updateTarget(now: now, force: true)
    }

    /// Termine la séance et renvoie le dernier tour fermé.
    func finish(now: Date = Date()) {
        guard isActive else { return }
        timer?.invalidate()
        timer = nil
        if let noSleepActivity { ProcessInfo.processInfo.endActivity(noSleepActivity) }
        noSleepActivity = nil
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

        updateAutoPause(now: now)
        guard state == .running else { return }

        elapsed += dt
        let speed = (source.speedKmh ?? 0) / 3.6
        distance += speed * dt

        updateTarget(now: now, force: false)
        if dt > 0 { recordSample(now: now, speed: speed) }
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
        let index = timeline.segmentIndex(at: elapsed)
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

        guard let watts = timeline.targetWatts(at: elapsed) else { return }
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

    private func recordSample(now: Date, speed: Double) {
        samples.append(Sample(timestamp: now,
                              elapsed: elapsed,
                              power: source.power,
                              cadence: source.cadence.map { Int($0.rounded()) },
                              heartRate: source.currentHeartRate,
                              speed: speed,
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
