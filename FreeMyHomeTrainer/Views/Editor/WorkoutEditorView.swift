import SwiftUI

struct WorkoutEditorView: View {
    let saved: SavedWorkout
    var onRide: () -> Void

    @AppStorage(Settings.ftpKey) private var ftp = 200
    @State private var draft: Workout
    @State private var selectedID: WorkoutBlock.ID?
    /// Glisser en cours (bloc existant ou nouveau bloc de la palette).
    @State private var dragState = BlockDragState()
    @State private var frames = BlockFrames()

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
                              frames: frames, dragState: dragState,
                              onDragChanged: dragChanged, onDragEnded: dragEnded,
                              onChangeCount: { id, count in
                                  guard var b = draft.blocks.find(id) else { return }
                                  b.count = min(max(count, 1), 50)
                                  draft.blocks.replace(id, with: b)
                              },
                              onUpdate: { draft.blocks.replace($0.id, with: $0) })
                editBar
            }
            .padding(20)
            .coordinateSpace(EditorSpace.coordinateSpace)
            // Le corps de l'éditeur ne lit pas l'état du glisser : un mouvement de souris
            // ne redessine que la superposition, pas toute la page.
            .overlay { BlockDragOverlay(state: dragState, frames: frames, blocks: draft.blocks, ftp: ftp) }
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
            Text("Ajouter :").foregroundStyle(.secondary)
            // Un bloc est constant à sa création ; il devient une rampe via la barre d'édition.
            PaletteItem(title: "Bloc", icon: "rectangle.fill",
                        onTap: { add(newBlock(.steady)) },
                        onDragChanged: { dragChanged(.new(.steady), $0) }, onDragEnded: dragEnded)
            PaletteItem(title: "Répétition", icon: "repeat",
                        onTap: { add(newBlock(.repeats)) },
                        onDragChanged: { dragChanged(.new(.repeats), $0) }, onDragEnded: dragEnded)
            Spacer(minLength: 0)
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
        withAnimation(Self.blockAnimation) { insert(block) }
    }

    private func insert(_ block: WorkoutBlock) {
        if let id = selectedID {
            draft.blocks.insert(block, relativeTo: id, after: true)
        } else {
            draft.blocks.append(block)
        }
        selectedID = block.id
    }

    /// Animation des ajouts et suppressions.
    private static let blockAnimation = Animation.easeInOut(duration: 0.2)

    // MARK: - Glisser-déposer

    private func dragChanged(_ payload: BlockDragPayload, _ location: CGPoint) {
        let target = BlockDropResolver.target(at: location, payload: payload, blocks: draft.blocks,
                                              items: frames.items, timeline: frames.timeline)
        dragState.update(payload: payload, location: location, target: target)
    }

    /// Lâcher : le bloc est posé directement à l'emplacement indiqué par le repère, sans
    /// animation de trajet (l'étiquette qui suivait le pointeur s'y trouve déjà).
    private func dragEnded(_ location: CGPoint) {
        guard let payload = dragState.payload else { return }
        let target = BlockDropResolver.target(at: location, payload: payload, blocks: draft.blocks,
                                              items: frames.items, timeline: frames.timeline)
        dragState.reset()
        if let target { applyDrop(payload, target) }
    }

    private func applyDrop(_ payload: BlockDragPayload, _ target: BlockDropTarget) {
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
                draft.blocks.insert(block, relativeTo: targetID, after: after)
            case .intoRepeat(let repeatID):
                draft.blocks.appendChild(block, toRepeat: repeatID)
            case .end:
                draft.blocks.append(block)
            }
            selectedID = block.id
        }
    }

    private func deleteSelection() {
        guard let id = selectedID else { return }
        withAnimation(Self.blockAnimation) {
            draft.blocks.remove(id)
            selectedID = nil
        }
    }

    /// Plage de temps couverte par le bloc sélectionné (première occurrence), pour l'aperçu.
    private var selectedRange: Range<TimeInterval>? {
        guard let id = selectedID else { return nil }
        func range(in blocks: [WorkoutBlock], from start: TimeInterval) -> Range<TimeInterval>? {
            var t = start
            for b in blocks {
                if b.id == id { return t..<(t + b.totalDuration) }
                if b.kind == .repeats, b.count > 0, let r = range(in: b.blocks, from: t) { return r }
                t += b.totalDuration
            }
            return nil
        }
        return range(in: draft.blocks, from: 0)
    }
}

/// Bouton de la palette : clic = ajout, glisser = dépôt à l'endroit voulu dans la frise.
private struct PaletteItem: View {
    let title: String
    let icon: String
    let onTap: () -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void

    var body: some View {
        Label(title, systemImage: icon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: EditorSpace.coordinateSpace)
                .onChanged { onDragChanged($0.location) }
                .onEnded { onDragEnded($0.location) })
            .help("Clique pour ajouter, ou glisse dans la frise")
    }
}
