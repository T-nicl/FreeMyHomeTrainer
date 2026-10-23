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
                    Text("Vitesses virtuelles : change de vitesse avec − / + ou les flèches ↓ ↑, comme sur la route. La sortie est enregistrée normalement.")
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
        VStack(spacing: 14) {
            header
            metrics
            blockCard
            secondaryStats
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

    /// Comme dans Zwift : les watts en très grand au centre, cardio et cadence plus petits,
    /// l'un au-dessus de l'autre, à côté.
    private var metrics: some View {
        let target = engine.targetWatts
        let power = engine.power3s
        return HStack(spacing: 14) {
            let guidance = PowerGuidance(power: power, target: target)
            MetricTile(title: "Watts", value: power.map(String.init) ?? "--", unit: "W",
                       caption: target.map { "Cible \($0) W" }, note: guidance?.advice,
                       accent: guidance?.color, valueSize: 104, centered: true)
            VStack(spacing: 14) {
                MetricTile(title: "Cardio", value: devices.currentHeartRate.map(String.init) ?? "--", unit: "bpm",
                           valueSize: 44)
                MetricTile(title: "Cadence", value: devices.cadence.map { String(Int(safe: $0)) } ?? "--",
                           unit: "rpm", valueSize: 44)
            }
            .frame(width: 260)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Bloc en cours : libellé, temps restant et barre de progression à la couleur de la zone.
    @ViewBuilder private var blockCard: some View {
        if let segment = engine.currentSegment, !engine.isWorkoutComplete {
            let color = PowerZone(watts: segment.averageWatts, ftp: engine.ftp).color
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(segment.label).font(.title2.weight(.semibold))
                    if let rep = segment.repetition {
                        Text("Répétition \(rep.index)/\(rep.count)").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(engine.segmentRemaining.map(Format.clock) ?? "--")
                        .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                        .layoutPriority(1)
                }
                // Une barre par bloc : au changement, elle repart de 0 sans animation de trajet.
                BlockProgressBar(progress: engine.segmentProgress ?? 0, color: color)
                    .id(segment.start)
                Text(engine.nextSegment.map { "Ensuite : \($0.label)" } ?? "Dernier bloc")
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(14)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
    }

    /// Données secondaires, en petit.
    private var secondaryStats: some View {
        ViewThatFits(in: .horizontal) {
            secondaryRow.font(.title3.monospacedDigit())
            secondaryRow.font(.body.monospacedDigit())
        }
        .lineLimit(1)
    }

    private var secondaryRow: some View {
        HStack(spacing: 24) {
            stat("Temps", Format.clock(engine.elapsed))
            if let remaining = engine.workoutRemaining, !engine.isWorkoutComplete {
                stat("Reste", Format.clock(remaining))
            }
            stat("Vitesse", String(format: "%.1f km/h", engine.speedKmh))
            stat("Distance", String(format: "%.2f km", engine.distance / 1000))
        }
        .frame(maxWidth: .infinity)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    @ViewBuilder private var chart: some View {
        let shown = downsampled(engine.samples)
        if let timeline = engine.timeline {
            WorkoutProfileChart(timeline: timeline, actual: shown, progress: engine.position)
                .frame(minHeight: 140)
        } else {
            FreeRideChart(samples: shown).frame(minHeight: 140)
        }
    }

    /// Limite le nombre de points tracés pour garder un affichage fluide.
    private func downsampled(_ samples: [Sample]) -> [Sample] {
        let stride = Sample.chartStride(count: samples.count)
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
            } else if let gear = engine.gear {
                // Sortie libre : vitesses virtuelles (la puissance suit la cadence et le développement).
                Button { engine.shift(by: -1) } label: { Image(systemName: "minus") }
                    .keyboardShortcut(.downArrow, modifiers: [])
                    .disabled(gear <= 1)
                    .help("Vitesse plus facile (↓)")
                Text("Vitesse \(gear)/\(VirtualGearbox.ratios.count)")
                    .monospacedDigit()
                    .fixedSize()
                Button { engine.shift(by: 1) } label: { Image(systemName: "plus") }
                    .keyboardShortcut(.upArrow, modifiers: [])
                    .disabled(gear >= VirtualGearbox.ratios.count)
                    .help("Vitesse plus dure (↑)")
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
    /// Consigne mise en avant à côté de la légende (« Accélère »), dans la couleur d'accent.
    var note: String?
    var accent: Color?
    var valueSize: CGFloat = 76
    /// Tuile principale : contenu centré.
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 2) {
            Text(title.uppercased()).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: valueSize, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(accent ?? .primary)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.4)
                Text(unit).font(.title2.weight(.medium)).foregroundStyle(.secondary).fixedSize()
            }
            if caption != nil || note != nil {
                HStack(spacing: 10) {
                    if let caption { Text(caption).foregroundStyle(.secondary) }
                    if let note { Text(note).fontWeight(.bold).foregroundStyle(accent ?? .primary) }
                }
                .font(.title3)
                .minimumScaleFactor(0.8)
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .center : .leading)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

extension PowerGuidance {
    /// Vert dans la cible, orange au-dessus comme en dessous.
    var color: Color { self == .onTarget ? .green : .orange }
}

/// Barre de progression du bloc en cours, remplie à la couleur de la zone.
private struct BlockProgressBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(color)
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
                    .animation(.linear(duration: 1), value: progress)
            }
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel("Progression du bloc")
        .accessibilityValue("\(Int(safe: progress * 100)) %")
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
