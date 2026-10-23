import Foundation
import Testing
@testable import FreeMyHomeTrainer

/// Lot 2 des relectures ECC : séances absurdes (import, chargement) et conversions numériques.
@MainActor
struct WorkoutLimitsTests {
    func json(_ blocks: String) -> Data { Data(#"{"name":"x","blocks":[\#(blocks)]}"#.utf8) }

    // Une séance venue de l'extérieur (JSON, LLM, ami) qui dépasse les limites est refusée.
    @Test func importRejectsAbsurdWorkouts() {
        let tooManyRepeats = json(#"{"type":"repeat","count":1000000000,"blocks":[{"type":"steady","duration":60,"target":{"watts":200}}]}"#)
        #expect(throws: WorkoutValidationError.self) { try Workout.importJSON(tooManyRepeats) }

        var nested = #"{"type":"steady","duration":60,"target":{"watts":200}}"#
        for _ in 0..<6 { nested = #"{"type":"repeat","count":2,"blocks":[\#(nested)]}"# }
        #expect(throws: WorkoutValidationError.self) { try Workout.importJSON(json(nested)) }

        let hugeWatts = json(#"{"type":"steady","duration":60,"target":{"watts":99999}}"#)
        #expect(throws: WorkoutValidationError.self) { try Workout.importJSON(hugeWatts) }

        let hugeDuration = json(#"{"type":"steady","duration":1e30,"target":{"watts":200}}"#)
        #expect(throws: (any Error).self) { try Workout.importJSON(hugeDuration) }

        // Une séance raisonnable passe, avec un message clair sinon.
        let fine = json(#"{"type":"repeat","count":3,"blocks":[{"type":"steady","duration":600,"target":{"ftp":90}}]}"#)
        #expect((try? Workout.importJSON(fine)) != nil)
        do {
            _ = try Workout.importJSON(tooManyRepeats)
        } catch {
            #expect(error.localizedDescription.contains("50"))
        }
    }

    // Une séance déjà enregistrée et absurde est ramenée dans les limites au chargement.
    @Test func storedAbsurdWorkoutIsSanitizedOnLoad() throws {
        let absurd = Workout(name: "x", blocks: [
            .repeats(1_000_000, [
                .steady(1e30, .watts(99_999)),
                .ramp(0.2, from: .ftpPercent(5000), to: .watts(-10)),
                .steady(-5, .watts(200)),                                  // durée négative : retiré
            ]),
        ])
        let loaded = SavedWorkout(absurd).workout
        let rep = try #require(loaded.blocks.first)
        #expect(rep.count == WorkoutLimits.maxRepeatCount)
        try #require(rep.blocks.count == 2)
        #expect(rep.blocks[0].duration == WorkoutLimits.maxBlockDuration)
        #expect(rep.blocks[0].target == .watts(WorkoutLimits.maxWatts))
        #expect(rep.blocks[1].duration == WorkoutLimits.minBlockDuration)
        #expect(rep.blocks[1].target == .ftpPercent(WorkoutLimits.maxFTPPercent))
        #expect(rep.blocks[1].endTarget == .watts(0))
    }

    // Relecture sécurité : des répétitions vides imbriquées ne produisent aucun segment et
    // échappaient au plafond — l'app se figeait (50⁶ itérations).
    @Test(.timeLimit(.minutes(1)))
    func emptyNestedRepeatsCannotHangTheApp() {
        var block = WorkoutBlock.repeats(50, [])
        for _ in 0..<5 { block = .repeats(50, [block]) }
        let w = Workout(name: "x", blocks: [block, .steady(60, .watts(150))])
        #expect(WorkoutTimeline(workout: w, ftp: 250).segments.count == 1)       // déroulé immédiat
        #expect(throws: WorkoutValidationError.self) { try w.validate() }        // import refusé
        let loaded = SavedWorkout(w).workout                                       // chargement assaini
        #expect(loaded.blocks.nestingDepth <= WorkoutLimits.maxDepth)
        #expect(loaded.blocks.count == 1)                                          // répétition vide retirée
    }

    @Test func depthLimitAcceptsFourLevelsRejectsFive() throws {
        func nest(_ levels: Int) -> Workout {
            var block = WorkoutBlock.steady(30, .watts(200))
            for _ in 0..<levels { block = .repeats(2, [block]) }
            return Workout(name: "x", blocks: [block])
        }
        try nest(4).validate()
        #expect(throws: WorkoutValidationError.self) { try nest(5).validate() }
        #expect(SavedWorkout(nest(7)).workout.blocks.nestingDepth == WorkoutLimits.maxDepth)
    }

    @Test func importRejectsOversizedInput() {
        let longName = String(repeating: "a", count: 1_000)
        let data = Data(#"{"name":"\#(longName)","blocks":[{"type":"steady","duration":60,"target":{"watts":200}}]}"#.utf8)
        #expect(throws: WorkoutValidationError.self) { try Workout.importJSON(data) }
        let huge = Data(repeating: 0x20, count: 300_000) + data
        #expect(throws: WorkoutValidationError.self) { try Workout.importJSON(huge) }
    }

    @Test func uniqueNameDoesNotOverflow() {
        let name = "Séance 9223372036854775807"
        #expect(!WorkoutNaming.unique(name, among: [name]).isEmpty)
    }

    // Filet de sécurité : le déroulé s'arrête net au nombre maximal de segments.
    @Test func timelineIsCappedEvenIfValidationIsBypassed() {
        let w = Workout(name: "x", blocks: [.repeats(50, [.repeats(50, [.repeats(50, [.steady(10, .watts(100))])])])])
        #expect(WorkoutTimeline(workout: w, ftp: 250).segments.count == WorkoutLimits.maxSegments)
    }

    // Les conversions numériques ne plantent jamais (valeurs infinies, invalides ou énormes).
    @Test func formattingNeverCrashes() {
        #expect(!Format.clock(.infinity).isEmpty)
        #expect(!Format.clock(.nan).isEmpty)
        #expect(!Format.duration(1e30).isEmpty)
        #expect(!Format.duration(-.infinity).isEmpty)
    }

    @Test func fitEncodingSurvivesAberrantSensorValues() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = (0..<5).map { i in
            Sample(timestamp: start.addingTimeInterval(TimeInterval(i + 1)), elapsed: TimeInterval(i + 1),
                   power: -5, cadence: -1, heartRate: 400, speed: .infinity, distance: .nan, target: -3)
        }
        let fit = FITEncoder.encode(FITActivity(startDate: start, endDate: start.addingTimeInterval(6), ftp: -1,
                                                samples: samples,
                                                laps: [Lap(startTime: start, endTime: start.addingTimeInterval(6),
                                                           timerTime: 5, sampleRange: 0..<5)]))
        #expect(FITCRC.compute(fit) == 0)
    }

    @Test func engineSurvivesAbsurdTargets() {
        let source = MockSource()
        let engine = WorkoutEngine(workout: Workout(name: "x", blocks: [.steady(60, .watts(Int.max))]),
                                   ftp: 250, source: source)
        engine.start(at: Date(timeIntervalSince1970: 0), autoTick: false)
        #expect(source.targets.first.map { $0 <= WorkoutLimits.maxWatts } == true)
    }
}
