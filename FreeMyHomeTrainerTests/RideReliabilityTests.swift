import AppKit
import Foundation
import SwiftData
import Testing
@testable import FreeMyHomeTrainer

/// Lot 1 de la relecture ECC : fiabilité d'une séance réelle (ERG, minuteries, fin, enregistrement).
@MainActor
struct RideReliabilityTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func engine(_ source: MockSource) -> WorkoutEngine {
        WorkoutEngine(workout: Workout(name: "x", blocks: [.steady(600, .watts(250)), .steady(300, .watts(120))]),
                      ftp: 245, source: source)
    }

    // Bug 1 : après une reprise de contrôle (reconnexion, autre app…), la consigne en cours
    // doit être renvoyée immédiatement, et non au prochain changement de palier.
    @Test func ergTargetIsResentWhenTrainerRegainsControl() {
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        for i in 1...5 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        #expect(source.targets == [250])
        source.controlGeneration += 1                     // le trainer vient de reprendre le contrôle
        e.tick(now: t0.addingTimeInterval(6))
        #expect(source.targets == [250, 250])
    }

    // Bug 2 : les minuteries doivent continuer pendant un déplacement de fenêtre ou un menu
    // (boucle d'événements en mode « suivi »).
    @Test func repeatingTimerFiresDuringEventTracking() {
        var fired = 0
        let timer = RepeatingTimer.schedule(every: 0.05) { fired += 1 }
        // `run(mode:before:)` rend la main après chaque passage : on boucle jusqu'à l'échéance.
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline { RunLoop.main.run(mode: .eventTracking, before: deadline) }
        timer.invalidate()
        #expect(fired >= 3)
    }

    // Bug 3 : « Terminer » en plein intervalle doit relâcher l'ERG.
    @Test func finishingMidWorkoutReleasesERG() {
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        for i in 1...10 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        e.finish(now: t0.addingTimeInterval(11))
        #expect(source.grades == [0])
    }

    // Bug 4 : un enregistrement qui échoue lève une erreur sans laisser de sortie à moitié
    // enregistrée (l'écran Rouler garde alors la séance pour réessayer).
    @Test func failedSaveThrowsAndLeavesNothing() throws {
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        for i in 1...10 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        e.finish(now: t0.addingTimeInterval(11))

        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let unwritable = URL(fileURLWithPath: "/dev/null/impossible", isDirectory: true)
        #expect(throws: (any Error).self) {
            try ActivitySaver.save(engine: e, context: container.mainContext, directory: unwritable)
        }
        let saved = try container.mainContext.fetch(FetchDescriptor<ActivityRecord>())
        #expect(saved.isEmpty)
        #expect(e.samples.count == 10)                    // les données de la séance sont intactes
    }

    // Bug 4 : si la base refuse l'enregistrement, le .fit déjà écrit est supprimé et la fiche
    // n'est pas gardée (aucun demi-enregistrement).
    @Test func failedDatabaseSaveRemovesTheFitFile() throws {
        struct DatabaseFull: Error {}
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        for i in 1...10 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        e.finish(now: t0.addingTimeInterval(11))

        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: DatabaseFull.self) {
            try ActivitySaver.save(engine: e, context: container.mainContext, directory: directory,
                                   persist: { _ in throw DatabaseFull() })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<ActivityRecord>()).isEmpty)
    }

    // La consigne est aussi renvoyée en pause : le trainer garde ainsi la bonne résistance
    // pour la reprise (comportement voulu, documenté ici).
    @Test func ergTargetIsResentWhilePaused() {
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        e.tick(now: t0.addingTimeInterval(1))
        e.togglePause()
        source.controlGeneration += 1
        e.tick(now: t0.addingTimeInterval(2))
        #expect(source.targets == [250, 250])
        #expect(e.elapsed == 1)                           // la pause n'est pas affectée
    }

    // Bug 4 (suite) : si l'enregistrement échoue, l'écran Rouler doit garder la séance en cours
    // pour pouvoir réessayer, au lieu de l'effacer.
    @Test func failedSaveKeepsTheRideForRetry() throws {
        let source = MockSource()
        let appState = AppState()
        let e = engine(source)
        appState.engine = e
        e.start(at: t0, autoTick: false)
        for i in 1...10 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }

        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let unwritable = URL(fileURLWithPath: "/dev/null/impossible", isDirectory: true)
        #expect(throws: (any Error).self) {
            try appState.finishRide(context: container.mainContext, directory: unwritable)
        }
        #expect(appState.engine === e)                    // séance conservée
        #expect(e.state == .finished)

        // Nouvel essai qui réussit : la séance est enregistrée puis libérée.
        let record = try appState.finishRide(context: container.mainContext,
                                             directory: FileManager.default.temporaryDirectory)
        #expect(record != nil)
        #expect(appState.engine == nil)
        if let url = record?.fitFileName.map({ FileManager.default.temporaryDirectory.appendingPathComponent($0) }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // Lot 4 — « Suivant » en pause : l'intervalle affiché et le tour sont mis à jour tout de suite.
    @Test func skippingWhilePausedUpdatesTheInterval() {
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        for i in 1...5 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        e.togglePause()
        e.skipSegment(now: t0.addingTimeInterval(6))
        #expect(e.currentSegment?.start == 600)
        #expect(e.segmentRemaining == 300)
        #expect(e.laps.count == 1)
        #expect(source.targets == [250, 120])
    }

    // Écran façon Zwift : barre de progression du bloc en cours (0 au début, 1 à la fin).
    @Test func segmentProgressFollowsTheCurrentBlock() {
        let source = MockSource()
        let e = engine(source)
        #expect(e.segmentProgress == nil)                     // avant le départ : aucun bloc en cours
        e.start(at: t0, autoTick: false)
        #expect(e.segmentProgress == 0)
        for i in 1...60 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        #expect(e.position > 0)
        #expect(abs((e.segmentProgress ?? -1) - e.position / 600) < 0.0001)
        e.skipSegment(now: t0.addingTimeInterval(61))
        #expect(e.segmentProgress == 0)                       // nouveau bloc : barre vide
        e.skipSegment(now: t0.addingTimeInterval(62))
        #expect(e.isWorkoutComplete)
        #expect(e.segmentProgress == nil)                     // séance terminée : plus de bloc

        let free = WorkoutEngine(workout: nil, ftp: 245, source: MockSource())
        #expect(free.segmentProgress == nil)                  // sortie libre : pas de bloc
    }

    // Régression : séance terminée, roue libre → le curseur et la courbe réelle sortaient du
    // profil par la droite. Ils s'arrêtent au bout de la séance.
    @Test func chartMarksStayInsideTheWorkoutAfterTheEnd() {
        #expect(WorkoutProfileChart.clamped(progress: 3_700, duration: 3_600) == 3_600)
        #expect(WorkoutProfileChart.clamped(progress: 120, duration: 3_600) == 120)
        #expect(WorkoutProfileChart.clamped(progress: nil, duration: 3_600) == nil)
        let samples = [3_590.0, 3_600, 3_610, 3_700].map {
            Sample(timestamp: t0, elapsed: $0, position: $0, power: 100, cadence: nil, heartRate: nil,
                   speed: nil, distance: 0, target: nil)
        }
        #expect(WorkoutProfileChart.withinWorkout(samples, duration: 3_600).map(\.elapsed) == [3_590, 3_600])
    }

    // Lot 4 — la courbe en direct ne doit pas « glisser » : le pas de sous-échantillonnage
    // change rarement (puissances de 2), et pas toutes les 15 minutes.
    @Test func liveChartStrideIsStable() {
        var changes = 0
        var previous = Sample.chartStride(count: 1)
        for count in 1...14_400 {                                   // 4 h à 1 Hz
            let stride = Sample.chartStride(count: count)
            if stride != previous { changes += 1; previous = stride }
            #expect(count / stride <= 900 * 2)                     // jamais plus de ~1 800 points
        }
        #expect(changes <= 4)
    }

    // Lot 4 (relecture) — une séance terminée (par ex. en attente d'enregistrement) ne doit plus
    // rien envoyer au trainer, même si « Suivant » est encore cliquable.
    @Test func skippingAfterFinishDoesNothing() {
        let source = MockSource()
        let e = engine(source)
        e.start(at: t0, autoTick: false)
        for i in 1...5 { e.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        e.finish(now: t0.addingTimeInterval(6))
        let laps = e.laps.count
        e.skipSegment(now: t0.addingTimeInterval(7))
        #expect(source.targets == [250])
        #expect(source.grades == [0])
        #expect(e.laps.count == laps)
    }
}
