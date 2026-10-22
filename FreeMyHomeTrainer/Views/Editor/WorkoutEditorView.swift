import SwiftUI

struct WorkoutEditorView: View {
    let saved: SavedWorkout
    var onRide: () -> Void

    @AppStorage(Settings.ftpKey) private var ftp = 200
    @State private var draft: Workout
    @State private var selectedID: WorkoutBlock.ID?

    init(saved: SavedWorkout, onRide: @escaping () -> Void) {
        self.saved = saved
        self.onRide = onRide
        _draft = State(initialValue: saved.workout)
    }

    var body: some View {
        let timeline = WorkoutTimeline(workout: draft, ftp: ftp)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(timeline)
                WorkoutProfileChart(timeline: timeline, highlightedRange: selectedRange, showAxes: false, showFTPLine: true)
                    .frame(height: 56)
                palette
                BlockTimeline(blocks: draft.blocks, ftp: ftp, selectedID: $selectedID,
                              onDrop: handleDrop,
                              onChangeCount: { id, count in
                                  guard var b = draft.blocks.find(id) else { return }
                                  b.count = min(max(count, 1), 50)
                                  draft.blocks.replace(id, with: b)
                              },
                              onUpdate: { draft.blocks.replace($0.id, with: $0) })
                editBar
            }
            .padding(20)
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { deleteSelection() }
        .onChange(of: draft) { _, new in saved.workout = new }
    }

    // MARK: - Sous-vues

    private func header(_ timeline: WorkoutTimeline) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Nom de la séance", text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                Button(action: onRide) {
                    Label("Rouler", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize()
                .disabled(draft.totalDuration == 0)
            }
            WorkoutSummaryRow(timeline: timeline)
            TextField("Notes (facultatif)", text: $draft.notes, axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .lineLimit(1...3)
        }
    }

    /// Blocs à ajouter : clic = ajout après la sélection, ou glisser dans la frise.
    private var palette: some View {
        HStack(spacing: 8) {
            PaletteItem(title: "Constant", icon: "rectangle.fill", kind: .steady) { add(newBlock(.steady)) }
            PaletteItem(title: "Rampe", icon: "chart.line.uptrend.xyaxis", kind: .ramp) { add(newBlock(.ramp)) }
            PaletteItem(title: "Répétition", icon: "repeat", kind: .repeats) { add(newBlock(.repeats)) }
            Spacer(minLength: 8)
            Text("Glisse les blocs pour les déplacer")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder private var editBar: some View {
        if let id = selectedID, let block = draft.blocks.find(id) {
            BlockEditBar(block: Binding(get: { draft.blocks.find(id) ?? block },
                                        set: { draft.blocks.replace(id, with: $0) }),
                         ftp: ftp,
                         onDuplicate: { if let copy = draft.blocks.duplicate(id) { selectedID = copy } },
                         onDelete: deleteSelection,
                         onAddChild: { kind in
                             let child = newBlock(kind)
                             draft.blocks.appendChild(child, toRepeat: id)
                             selectedID = child.id
                         })
        } else {
            Label("Clique sur un bloc pour le régler, ou tire sur son bord droit (durée) ou son haut (puissance).",
                  systemImage: "hand.tap")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Édition

    /// Nouveaux blocs en watts, à partir d'un pourcentage de la FTP (arrondi à 5 W).
    private func newBlock(_ kind: WorkoutBlock.Kind) -> WorkoutBlock {
        let w = { (percent: Double) in Target.watts(Self.roundedWatts(Double(ftp) * percent)) }
        return switch kind {
        case .steady: .steady(300, w(0.75))
        case .ramp: .ramp(300, from: w(0.5), to: w(0.75))
        case .repeats: .repeats(3, [.steady(300, w(1.0)), .steady(180, w(0.55))])
        }
    }

    static func roundedWatts(_ watts: Double) -> Int { Int((watts / 5).rounded()) * 5 }

    /// Ajoute après le bloc sélectionné (une répétition n'est jamais imbriquée), sinon à la fin.
    private func add(_ block: WorkoutBlock) {
        if let id = selectedID {
            let anchor = block.kind == .repeats ? (draft.blocks.parentID(of: id) ?? id) : id
            draft.blocks.insert(block, relativeTo: anchor, after: true)
        } else {
            draft.blocks.append(block)
        }
        selectedID = block.id
    }

    private func handleDrop(_ payload: BlockDragPayload, _ target: BlockDropTarget) {
        switch payload {
        case .existing(let id):
            switch target {
            case .relative(let targetID, let after): draft.blocks.moveBlock(id, relativeTo: targetID, after: after)
            case .intoRepeat(let repeatID): draft.blocks.moveBlock(id, intoRepeat: repeatID)
            case .end: draft.blocks.moveBlockToEnd(id)
            }
            selectedID = id
        case .new(let kind):
            let block = newBlock(kind)
            switch target {
            case .relative(let targetID, let after):
                // Une répétition déposée dans une répétition va à côté de celle-ci.
                let anchor = draft.blocks.canPlace(block, nextTo: targetID)
                    ? targetID : (draft.blocks.parentID(of: targetID) ?? targetID)
                draft.blocks.insert(block, relativeTo: anchor, after: after)
            case .intoRepeat(let repeatID):
                if kind == .repeats {
                    draft.blocks.insert(block, relativeTo: repeatID, after: true)
                } else {
                    draft.blocks.appendChild(block, toRepeat: repeatID)
                }
            case .end:
                draft.blocks.append(block)
            }
            selectedID = block.id
        }
    }

    private func deleteSelection() {
        guard let id = selectedID else { return }
        draft.blocks.remove(id)
        selectedID = nil
    }

    /// Plage de temps couverte par le bloc sélectionné (première occurrence), pour l'aperçu.
    private var selectedRange: Range<TimeInterval>? {
        guard let id = selectedID else { return nil }
        var t: TimeInterval = 0
        for b in draft.blocks {
            if b.id == id { return t..<(t + b.totalDuration) }
            if b.kind == .repeats {
                var inner = t
                for child in b.blocks {
                    if child.id == id { return inner..<(inner + child.duration) }
                    inner += child.duration
                }
            }
            t += b.totalDuration
        }
        return nil
    }
}

private struct PaletteItem: View {
    let title: String
    let icon: String
    let kind: WorkoutBlock.Kind
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .fixedSize()
        }
        .onDrag { BlockDragPayload.new(kind).itemProvider() }
        .help("Clique pour ajouter, ou glisse dans la frise")
    }
}
