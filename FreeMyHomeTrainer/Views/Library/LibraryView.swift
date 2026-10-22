import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \SavedWorkout.updatedAt, order: .reverse) private var workouts: [SavedWorkout]
    @AppStorage(Settings.ftpKey) private var ftp = 200
    @State private var selection: SavedWorkout.ID?

    var body: some View {
        HStack(spacing: 0) {
            List(workouts, selection: $selection) { saved in
                LibraryRow(workout: saved.workout, ftp: ftp)
                    .tag(saved.id)
                    .contextMenu {
                        Button("Rouler cette séance") { ride(saved) }
                        Button("Dupliquer") { duplicate(saved) }
                        Divider()
                        Button("Supprimer", role: .destructive) { delete(saved) }
                    }
            }
            .frame(width: 250)

            Divider()

            Group {
                if let saved = selected {
                    WorkoutEditorView(saved: saved, onRide: { ride(saved) })
                        .id(saved.id)
                } else {
                    ContentUnavailableView("Aucune séance sélectionnée",
                                           systemImage: "list.bullet.rectangle",
                                           description: Text("Choisis une séance ou crée-en une nouvelle."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Séances")
        .toolbar {
            ToolbarItemGroup {
                Button { create() } label: { Label("Nouvelle séance", systemImage: "plus") }
                Button { if let s = selected { duplicate(s) } } label: {
                    Label("Dupliquer", systemImage: "plus.square.on.square")
                }
                .disabled(selected == nil)
                Button(role: .destructive) { if let s = selected { delete(s) } } label: {
                    Label("Supprimer", systemImage: "trash")
                }
                .disabled(selected == nil)
            }
        }
        .onAppear {
            if selection == nil { selection = appState.selectedWorkoutID ?? workouts.first?.id }
        }
    }

    private var selected: SavedWorkout? { workouts.first { $0.id == selection } }

    private func create() {
        let watts = { (percent: Double) in Target.watts(WorkoutEditorView.roundedWatts(Double(ftp) * percent)) }
        let w = Workout(name: "Nouvelle séance", blocks: [
            .ramp(600, from: watts(0.45), to: watts(0.7)),
            .repeats(3, [.steady(600, watts(0.9)), .steady(300, watts(0.55))]),
            .steady(300, watts(0.5)),
        ])
        let saved = SavedWorkout(w)
        context.insert(saved)
        selection = saved.id
    }

    private func duplicate(_ saved: SavedWorkout) {
        var w = saved.workout
        w.name += " (copie)"
        let copy = SavedWorkout(w)
        context.insert(copy)
        selection = copy.id
    }

    private func delete(_ saved: SavedWorkout) {
        if selection == saved.id { selection = nil }
        context.delete(saved)
    }

    private func ride(_ saved: SavedWorkout) {
        appState.selectedWorkoutID = saved.id
        appState.section = .ride
    }
}

private struct LibraryRow: View {
    let workout: Workout
    let ftp: Int

    var body: some View {
        let timeline = WorkoutTimeline(workout: workout, ftp: ftp)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(workout.name).font(.headline).lineLimit(1)
                Spacer()
                Text(Format.duration(timeline.duration))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            WorkoutProfileChart(timeline: timeline, showAxes: false)
                .frame(height: 36)
                .allowsHitTesting(false)
            IntensityStars(rating: timeline.intensityRating, size: 11)
        }
        .lineLimit(1)
        .padding(.vertical, 4)
    }
}
