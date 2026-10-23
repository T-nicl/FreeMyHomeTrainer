import AppKit
import Charts
import SwiftData
import SwiftUI

struct RideView: View {
    @Environment(AppState.self) private var appState
    @Environment(DeviceManager.self) private var devices
    @Environment(UploadCenter.self) private var uploads
    @Environment(\.modelContext) private var context
    @AppStorage(Settings.ftpKey) private var ftp = 200
    @AppStorage(Settings.weightKey) private var weight = 70.0
    @State private var finishedActivity: ActivityRecord?
    @State private var saveError: String?
    @State private var confirmAbandon = false

    var body: some View {
        Group {
            if let engine = appState.engine {
                LiveRideView(engine: engine, onFinish: finish)
            } else if let activity = finishedActivity {
                RideSummaryView(activity: activity) { finishedActivity = nil }
            } else {
                RideSetupView(onStart: start)
            }
        }
        .navigationTitle("Rouler")
        // La séance reste en mémoire tant qu'elle n'est pas enregistrée : on peut réessayer.
        .alert("Enregistrement impossible", isPresented: Binding(get: { saveError != nil },
                                                                   set: { if !$0 { saveError = nil } })) {
            Button("Réessayer") {
                saveError = nil
                finish()
            }
            Button("Abandonner la séance…", role: .destructive) {
                saveError = nil
                confirmAbandon = true
            }
            Button("Plus tard", role: .cancel) { saveError = nil }
        } message: {
            Text("\(saveError ?? "")\n\nTa séance n'est pas perdue : tu peux réessayer maintenant, ou plus tard avec le bouton « Terminer ».")
        }
        .confirmationDialog("Abandonner la séance sans l'enregistrer ?", isPresented: $confirmAbandon) {
            Button("Abandonner la séance", role: .destructive) { appState.engine = nil }
            Button("Réessayer l'enregistrement") { finish() }
        } message: {
            Text("Les données de cette sortie seront définitivement perdues.")
        }
    }

    private func start(_ workout: Workout?) {
        let engine = WorkoutEngine(workout: workout, ftp: ftp, riderWeight: weight, source: devices)
        engine.onCue = { cue in
            NSSound(named: cue == .countdown ? "Tink" : "Glass")?.play()
        }
        engine.start()
        appState.engine = engine
    }

    private func finish() {
        MiniOverlay.shared.close()
        do {
            if let record = try appState.finishRide(context: context) {
                uploads.uploadAfterRide(record, context: context)
                finishedActivity = record
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

// MARK: - Préparation

private struct RideSetupView: View {
    @Environment(AppState.self) private var appState
    @Environment(DeviceManager.self) private var devices
    /// Même ordre que la liste des séances.
    @Query(sort: [SortDescriptor(\SavedWorkout.sortOrder), SortDescriptor(\SavedWorkout.createdAt, order: .reverse)])
    private var workouts: [SavedWorkout]
    @AppStorage(Settings.ftpKey) private var ftp = 200
    let onStart: (Workout?) -> Void

    /// nil = sortie libre.
    private var selectedWorkout: Workout? {
        workouts.first { $0.id == appState.selectedWorkoutID }?.workout
    }

    var body: some View {
        @Bindable var appState = appState
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DevicesPanel()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Comptes").font(.title2.weight(.semibold))
                        AccountsPanel(compact: true)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(width: 320)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Séance").font(.title2.weight(.semibold))
                    Spacer()
                    Text("FTP \(ftp) W").foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Picker("Séance", selection: $appState.selectedWorkoutID) {
                    Text("Sortie libre (sans consigne)").tag(UUID?.none)
                    Divider()
                    ForEach(workouts) { w in
                        Text(w.name).tag(Optional(w.id))
                    }
                }
                .labelsHidden()

                if let workout = selectedWorkout {
                    let timeline = WorkoutTimeline(workout: workout, ftp: ftp)
                    WorkoutProfileChart(timeline: timeline).frame(height: 200)
                    WorkoutSummaryRow(timeline: timeline)
                    SanityBanner(warnings: WorkoutSanity.warnings(for: workout, ftp: ftp))
                    if !workout.notes.isEmpty {
                        Text(workout.notes).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Le trainer reste en mode résistance libre ; la sortie est enregistrée normalement.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack {
                    Group {
                        if devices.trainerState != .connected {
                            Label("Connecte un home trainer ou active le simulateur.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        } else if selectedWorkout != nil, !devices.hasControl {
                            Label("Le trainer n'a pas encore accepté le mode ERG.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                    .lineLimit(2)
                    Spacer(minLength: 8)
                    Button { onStart(selectedWorkout) } label: {
                        Label("Démarrer", systemImage: "play.fill").padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .fixedSize()
                    .disabled(devices.trainerState != .connected)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
    }
}

// MARK: - En cours

private struct LiveRideView: View {
    let engine: WorkoutEngine
    let onFinish: () -> Void
    @Environment(DeviceManager.self) private var devices
    @State private var confirmFinish = false

    var body: some View {
        VStack(spacing: 18) {
            header
            metrics
            intervalBanner
            chart
            controls
        }
        .padding(24)
        .confirmationDialog("Terminer la séance ?", isPresented: $confirmFinish) {
            Button("Terminer et enregistrer", action: onFinish)
            Button("Continuer", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text(engine.workout?.name ?? "Sortie libre").font(.title.weight(.bold)).lineLimit(1)
            stateBadge.lineLimit(1).fixedSize()
            Spacer()
            if let remaining = engine.workoutRemaining, !engine.isWorkoutComplete {
                Text("Reste \(Format.clock(remaining))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var stateBadge: some View {
        switch engine.state {
        case .paused: badge("En pause", .orange)
        case .autoPaused: badge("Pause auto — pédale pour reprendre", .orange)
        case .running where engine.isWorkoutComplete: badge("Séance terminée — roue libre", .green)
        default: EmptyView()
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var metrics: some View {
        let target = engine.targetWatts
        let power = engine.power3s
        return HStack(spacing: 14) {
            MetricTile(title: "Puissance", value: power.map(String.init) ?? "--", unit: "W",
                       caption: target.map { "Cible \($0) W" },
                       accent: powerColor(power: power, target: target), large: true)
            MetricTile(title: "Intervalle", value: engine.segmentRemaining.map(Format.clock) ?? "--",
                       unit: "", caption: engine.currentSegment?.label, large: true)
            MetricTile(title: "Cadence", value: devices.cadence.map { String(Int($0.rounded())) } ?? "--", unit: "rpm")
            MetricTile(title: "Cardio", value: devices.currentHeartRate.map(String.init) ?? "--", unit: "bpm",
                       accent: devices.currentHeartRate == nil ? nil : .red)
            MetricTile(title: "Vitesse", value: String(format: "%.1f", engine.speedKmh), unit: "km/h",
                       caption: String(format: "%.2f km", engine.distance / 1000))
            MetricTile(title: "Temps", value: Format.clock(engine.elapsed), unit: "")
        }
    }

    /// Vert si on est à ±5 % de la cible, orange en dessous, rouge au-dessus.
    private func powerColor(power: Int?, target: Int?) -> Color? {
        guard let power, let target, target > 0 else { return nil }
        let ratio = Double(power) / Double(target)
        if ratio < 0.95 { return .orange }
        if ratio > 1.05 { return .red }
        return .green
    }

    @ViewBuilder private var intervalBanner: some View {
        if let segment = engine.currentSegment {
            HStack {
                if let rep = segment.repetition {
                    Text("Répétition \(rep.index)/\(rep.count)").font(.headline)
                }
                Text(segment.label).font(.headline)
                Spacer()
                if let next = engine.nextSegment {
                    Text("Ensuite : \(next.label)").foregroundStyle(.secondary)
                } else {
                    Text("Dernier intervalle").foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .padding(12)
            .background(PowerZone(watts: segment.averageWatts, ftp: engine.ftp).color.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder private var chart: some View {
        let shown = downsampled(engine.samples)
        if let timeline = engine.timeline {
            WorkoutProfileChart(timeline: timeline, actual: shown, progress: engine.position)
                .frame(minHeight: 180)
        } else {
            FreeRideChart(samples: shown).frame(minHeight: 180)
        }
    }

    /// Limite le nombre de points tracés pour garder un affichage fluide.
    private func downsampled(_ samples: [Sample]) -> [Sample] {
        let stride = max(samples.count / 900, 1)
        guard stride > 1 else { return samples }
        return samples.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if engine.timeline != nil {
                Button { engine.adjustIntensity(by: -0.05) } label: { Image(systemName: "minus") }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .help("Baisser l'intensité de 5 % (↓)")
                Text("Intensité \(Int(safe: engine.intensity * 100)) %")
                    .monospacedDigit()
                    .fixedSize()
                Button { engine.adjustIntensity(by: 0.05) } label: { Image(systemName: "plus") }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .help("Augmenter l'intensité de 5 % (↑)")
                Button { engine.skipSegment() } label: { Label("Suivant", systemImage: "forward.end.fill") }
                    .disabled(engine.currentSegment == nil)
                    .help("Passer à l'intervalle suivant")
            }
            Spacer(minLength: 8)
            Button { MiniOverlay.shared.show(engine: engine, devices: devices) } label: {
                Label("Mini", systemImage: "pip.enter")
            }
            .help("Réduire en mini-fenêtre au-dessus de tout (pour regarder une vidéo en plein écran)")
            Button { engine.togglePause() } label: {
                Label(engine.state == .paused ? "Reprendre" : "Pause",
                      systemImage: engine.state == .paused ? "play.fill" : "pause.fill")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button(role: .destructive) { confirmFinish = true } label: {
                Label("Terminer", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .lineLimit(1)
        .controlSize(.large)
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    var caption: String?
    var accent: Color?
    var large = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: large ? 56 : 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent ?? .primary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.4)
                if !unit.isEmpty {
                    Text(unit).font(.title3).foregroundStyle(.secondary).fixedSize()
                }
            }
            Text(caption ?? " ").font(.callout).foregroundStyle(.secondary).minimumScaleFactor(0.8)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FreeRideChart: View {
    let samples: [Sample]

    var body: some View {
        Chart(samples, id: \.elapsed) { s in
            LineMark(x: .value("Temps", s.elapsed), y: .value("Puissance", s.power ?? 0))
                .foregroundStyle(.blue)
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel { if let t = value.as(Double.self) { Text(Format.duration(t)) } }
            }
        }
    }
}

// MARK: - Fin de séance

private struct RideSummaryView: View {
    let activity: ActivityRecord
    let onDone: () -> Void
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text("Bravo !").font(.largeTitle.weight(.bold))
            Text(activity.name).font(.title2).foregroundStyle(.secondary)
            ActivityStatsGrid(activity: activity)
                .frame(maxWidth: 640)
            UploadStatusView(activity: activity)
            HStack {
                Button("Voir dans l'historique") {
                    appState.section = .history
                    onDone()
                }
                Button("Nouvelle sortie", action: onDone).buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
