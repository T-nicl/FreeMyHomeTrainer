import SwiftData
import SwiftUI

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    /// Ordre choisi par l'utilisateur ; à égalité (séances jamais réordonnées), les plus récentes d'abord.
    @Query(sort: [SortDescriptor(\SavedWorkout.sortOrder), SortDescriptor(\SavedWorkout.createdAt, order: .reverse)])
    private var workouts: [SavedWorkout]
    @AppStorage(Settings.ftpKey) private var ftp = 200
    @State private var selection: SavedWorkout.ID?
    @State private var pendingDeletion: SavedWorkout?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                listHeader
                Divider()
                List(selection: $selection) {
                    ForEach(workouts) { saved in
                        LibraryRow(workout: saved.workout, ftp: ftp)
                            .tag(saved.id)
                            .contextMenu {
                                Button("Rouler cette séance") { ride(saved) }
                                Button("Dupliquer") { duplicate(saved) }
                                Divider()
                                Button("Supprimer…", role: .destructive) { pendingDeletion = saved }
                            }
                    }
                    .onMove(perform: move)
                }
                .onDeleteCommand { pendingDeletion = selected }
                Divider()
                listActions
            }
            .frame(width: 250)

            Divider()

            Group {
                if let saved = selected {
                    WorkoutEditorView(saved: saved,
                                      otherNames: workouts.filter { $0.id != saved.id }.map(\.name),
                                      onRide: { ride(saved) })
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
        .confirmationDialog("Supprimer « \(pendingDeletion?.name ?? "") » ?",
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } })) {
            Button("Supprimer", role: .destructive) {
                if let saved = pendingDeletion { delete(saved) }
                pendingDeletion = nil
            }
        } message: {
            Text("La séance sera définitivement supprimée. L'historique des sorties n'est pas touché.")
        }
        .onAppear {
            normalizeOrder()
            normalizeNames()
            if selection == nil { selection = appState.selectedWorkoutID ?? workouts.first?.id }
        }
    }

    /// En-tête de la liste, avec le bouton de création bien visible.
    private var listHeader: some View {
        HStack {
            Text("Mes séances").font(.headline)
            Spacer()
            Button { create() } label: { Label("Nouvelle séance", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Créer une nouvelle séance (⌘N)")
                .keyboardShortcut("n", modifiers: .command)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Boutons sous la liste, à la manière des listes macOS.
    private var listActions: some View {
        HStack(spacing: 2) {
            Button { if let s = selected { duplicate(s) } } label: {
                Image(systemName: "plus.square.on.square").frame(width: 24, height: 22)
            }
            .help("Dupliquer la séance")
            .disabled(selected == nil)
            Spacer()
            Button { pendingDeletion = selected } label: { Image(systemName: "trash").frame(width: 24, height: 22) }
                .help("Supprimer la séance (⌫)")
                .disabled(selected == nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var selected: SavedWorkout? { workouts.first { $0.id == selection } }

    // MARK: - Ordre

    /// Enregistre l'ordre donné (0, 1, 2…).
    private func renumber(_ ordered: [SavedWorkout]) {
        for (i, saved) in ordered.enumerated() where saved.sortOrder != i { saved.sortOrder = i }
    }

    /// Séances créées avant l'ordre manuel (toutes à 0) : on fige l'ordre affiché.
    private func normalizeOrder() {
        if Set(workouts.map(\.sortOrder)).count < workouts.count { renumber(workouts) }
    }

    /// Doublons hérités d'avant la règle des noms uniques : on numérote les suivants.
    private func normalizeNames() {
        var seen: [String] = []
        for saved in workouts {
            let unique = WorkoutNaming.unique(saved.name, among: seen)
            if unique != saved.name {
                var w = saved.workout
                w.name = unique
                saved.workout = w
            }
            seen.append(unique)
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ordered = workouts
        ordered.move(fromOffsets: source, toOffset: destination)
        renumber(ordered)
    }

    // MARK: - Actions

    private func create() {
        let watts = { (percent: Double) in Target.watts(WorkoutEditorView.roundedWatts(Double(ftp) * percent)) }
        let w = Workout(name: "Nouvelle séance", blocks: [
            .ramp(600, from: watts(0.45), to: watts(0.7)),
            .repeats(3, [.steady(600, watts(0.9)), .steady(300, watts(0.55))]),
            .steady(300, watts(0.5)),
        ])
        var named = w
        named.name = WorkoutNaming.unique(w.name, among: workouts.map(\.name))
        let saved = SavedWorkout(named)
        context.insert(saved)
        renumber([saved] + workouts)          // en tête de liste
        selection = saved.id
    }

    private func duplicate(_ saved: SavedWorkout) {
        var w = saved.workout
        w.name = WorkoutNaming.unique("\(w.name) (copie)", among: workouts.map(\.name))
        let copy = SavedWorkout(w)
        context.insert(copy)
        var ordered = workouts.filter { $0.id != copy.id }
        let index = (ordered.firstIndex { $0.id == saved.id } ?? -1) + 1
        ordered.insert(copy, at: index)       // juste sous l'original
        renumber(ordered)
        selection = copy.id
    }

    private func delete(_ saved: SavedWorkout) {
        if selection == saved.id {
            // Sélectionne la séance suivante (ou précédente) plutôt que rien.
            let index = workouts.firstIndex { $0.id == saved.id } ?? 0
            let remaining = workouts.filter { $0.id != saved.id }
            selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        }
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
