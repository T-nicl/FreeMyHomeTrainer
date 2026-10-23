import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import FreeMyHomeTrainer

/// Rendu réel de l'app dans une fenêtre hors écran : détecte les écrans qui s'affichent vides.
///
/// Régression : avec une séance démesurée, cliquer sur « Rouler » depuis l'éditeur affichait une
/// fenêtre entièrement blanche (bandeau d'alerte en `.fixedSize(vertical:)` dans un VStack avec
/// Spacer : mise en page insoluble). Aucun plantage ni message : seul un rendu le révèle.
@MainActor
struct RideScreenTests {
    /// Proportion de points différents du fond après être passé de l'éditeur à l'écran Rouler.
    func drawnRatioAfterRide(_ workout: Workout) throws -> Double {
        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let saved = SavedWorkout(workout)
        container.mainContext.insert(saved)
        UserDefaults.standard.set(true, forKey: Settings.seededKey)
        let appState = AppState()
        appState.section = .library
        let hosting = NSHostingView(rootView: ContentView()
            .environment(DeviceManager())
            .environment(appState)
            .environment(UploadCenter())
            .modelContainer(container)
            .frame(width: 1000, height: 680))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        func settle() {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
            hosting.layoutSubtreeIfNeeded()
        }
        settle()
        // Comme le bouton « Rouler » de l'éditeur.
        appState.selectedWorkoutID = saved.id
        appState.section = .ride
        settle()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let background = rep.colorAt(x: rep.pixelsWide / 2, y: 4)
        var differing = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                total += 1
                if rep.colorAt(x: x, y: y) != background { differing += 1 }
            }
        }
        return Double(differing) / Double(total)
    }

    @Test func rideScreenIsNotBlankForAnUnrealisticWorkout() throws {
        let unrealistic = Workout(name: "Séance démesurée", blocks: [
            .ramp(600, from: .ftpPercent(45), to: .ftpPercent(65)),
            .repeats(3, [.steady(300, .watts(540)), .steady(390, .watts(160))]),
            .steady(300, .ftpPercent(50)),
        ])
        let normal = try drawnRatioAfterRide(Workout.samples[0])
        let withWarning = try drawnRatioAfterRide(unrealistic)
        // Écran vide ≈ 0,20 (fond et bord seulement) ; écran normal ≈ 0,38.
        #expect(normal > 0.3)
        #expect(withWarning > 0.3)
    }

    /// Écran en séance (façon Zwift) : grands chiffres, carte du bloc avec barre de progression.
    /// L'image est écrite dans le dossier temporaire du conteneur pour la regarder.
    @Test func liveRideScreenIsNotBlank() throws {
        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        UserDefaults.standard.set(true, forKey: Settings.seededKey)
        let appState = AppState()
        appState.section = .ride
        let engine = WorkoutEngine(workout: Workout.samples[0], ftp: 245, source: MockSource())
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        engine.start(at: t0, autoTick: false)
        for i in 1...200 { engine.tick(now: t0.addingTimeInterval(TimeInterval(i))) }
        appState.engine = engine
        let hosting = NSHostingView(rootView: ContentView()
            .environment(DeviceManager())
            .environment(appState)
            .environment(UploadCenter())
            .modelContainer(container)
            .frame(width: 1000, height: 680))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        hosting.layoutSubtreeIfNeeded()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appending(path: "live-ride.png")
        try rep.representation(using: .png, properties: [:])?.write(to: url)
        print("CAPTURE \(url.path)")
        let background = rep.colorAt(x: rep.pixelsWide / 2, y: 4)
        var differing = 0, total = 0
        for x in stride(from: 0, to: rep.pixelsWide, by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                total += 1
                if rep.colorAt(x: x, y: y) != background { differing += 1 }
            }
        }
        #expect(Double(differing) / Double(total) > 0.3)
        appState.engine = nil
    }
}
