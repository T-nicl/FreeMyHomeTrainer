import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import FreeMyHomeTrainer

/// Régression : déplacer un bloc saccadait dès qu'un bloc était sélectionné (après un premier
/// dépôt, le bloc déplacé l'est). Un vrai glisser relance une mise en page à chaque mouvement ;
/// la barre d'édition affichée (champs de saisie dans des `ViewThatFits`) recréait alors ses
/// champs à chaque passe. Une passe de mise en page doit coûter à peu près autant avec la barre
/// d'édition que sans.
@MainActor
struct EditorDragLayoutTests {
    /// Durée moyenne (ms) d'un mouvement de pointeur dans le vrai éditeur.
    func msPerMove(selectFirstBlock: Bool) throws -> Double {
        let container = try ModelContainer(for: SavedWorkout.self, ActivityRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let saved = SavedWorkout(Workout(name: "Test", blocks: (0..<8).map { .steady(300, .watts(150 + $0 * 10)) }))
        container.mainContext.insert(saved)
        let state = BlockDragState()
        let view = WorkoutEditorView(saved: saved, otherNames: [], onRide: {}, dragState: state,
                                     selectFirstBlock: selectFirstBlock)
            .modelContainer(container)
            .frame(minWidth: 900, minHeight: 760)
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        state.update(payload: .new(.steady), location: CGPoint(x: 100, y: 400), target: nil)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let moves = 60
        let start = Date()
        for i in 1...moves {
            // Comme un vrai glisser : nouvelle position et nouvelle passe de mise en page.
            state.update(payload: .new(.steady), location: CGPoint(x: 100 + Double(i) * 8, y: 400), target: nil)
            window.setContentSize(NSSize(width: 900 + Double(i % 2), height: 760))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        return Date().timeIntervalSince(start) / Double(moves) * 1000
    }

    @Test func dragStaysLightWithABlockSelected() throws {
        let unselected = try msPerMove(selectFirstBlock: false)
        let selected = try msPerMove(selectFirstBlock: true)
        print("DRAG ms/mouvement : sans sélection \(unselected), avec \(selected)")
        #expect(selected < max(unselected * 1.5, unselected + 1))
    }
}
