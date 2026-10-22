import SwiftUI

/// Frise de la séance : chaque bloc est une barre (largeur = durée, hauteur = puissance).
/// Clic pour sélectionner, glisser pour déplacer.
struct BlockTimeline: View {
    let blocks: [WorkoutBlock]
    let ftp: Int
    @Binding var selectedID: WorkoutBlock.ID?
    /// Positions des éléments, mesurées ici et lues par l'éditeur pendant un glisser.
    let frames: BlockFrames
    let drag: BlockDrag?
    let onDragChanged: (BlockDragPayload, CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onChangeCount: (WorkoutBlock.ID, Int) -> Void
    /// Bloc modifié en tirant sur ses bords.
    let onUpdate: (WorkoutBlock) -> Void

    static let barHeight: CGFloat = 150
    /// Espace entre deux blocs ; le repère d'insertion est dessiné en son milieu.
    static let gap: CGFloat = 4
    static let minBarWidth: CGFloat = 54
    private static let groupPadding: CGFloat = 8
    /// Hauteur ajoutée par un groupe de répétition : marge haute + en-tête « × n ».
    private static let groupHeader: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let scale = pointsPerSecond(width: geo.size.width)
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: Self.gap) {
                    ForEach(blocks) { block in element(block, depth: 0, scale: scale) }
                    if blocks.isEmpty { EmptyDropZone(isTargeted: drag?.target == .end) }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 8 + Self.groupPadding)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = nil }
            }
        }
        // Chaque niveau de répétition imbriquée ajoute un en-tête au-dessus des barres.
        .frame(height: Self.barHeight + 100 + CGFloat(max(blocks.nestingDepth - 1, 0)) * Self.groupHeader)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .bottomLeading) { ftpLine }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: EditorSpace.coordinateSpace) } action: {
            frames.timeline = $0
        }
    }

    private var draggedID: WorkoutBlock.ID? {
        if case .existing(let id) = drag?.payload { return id }
        return nil
    }

    private func measure(_ id: WorkoutBlock.ID, isRepeat: Bool, depth: Int) -> (CGRect) -> Void {
        { [frames] rect in frames.items[id] = BlockFrames.Item(rect: rect, isRepeat: isRepeat, depth: depth) }
    }

    /// Distance entre le bas de la frise et le bas des barres :
    /// marge (8) + marge des blocs (8) + libellés sous les barres (18 + 15 + 2 × 2).
    private static let barBaseline: CGFloat = 8 + groupPadding + 37

    /// Trait pointillé à la hauteur de la FTP, aligné sur l'échelle des barres.
    @ViewBuilder private var ftpLine: some View {
        if ftp > 0 {
            let fraction = min(Double(ftp) / maxWatts, 1)
            HStack(spacing: 6) {
                Text("FTP \(ftp) W")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle()
                    .fill(.clear)
                    .frame(height: 1)
                    .overlay(Line().stroke(.secondary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            }
            .padding(.horizontal, 8)
            .frame(height: 12)
            .offset(y: -(Self.barBaseline + Self.barHeight * fraction) + 6)
            .opacity(0.8)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Échelles

    private func pointsPerSecond(width: CGFloat) -> CGFloat {
        let total = blocks.reduce(0) { $0 + $1.displayDuration }
        guard total > 0 else { return 0 }
        let groups = CGFloat(blocks.repeatCount)
        let overhead = 24 + CGFloat(blocks.leafCount + blocks.repeatCount) * Self.gap
            + groups * (Self.groupPadding * 2 + 8)
        return max((width - overhead) / total, 0)
    }

    private var maxWatts: Double {
        let peak = blocks.leaves.map { max($0.target.watts(ftp: ftp), $0.endTarget.watts(ftp: ftp)) }.max() ?? 0
        return max(peak * 1.08, Double(ftp) * 1.2, 1)
    }

    // MARK: - Éléments

    private func bar(_ block: WorkoutBlock, depth: Int, scale: CGFloat) -> some View {
        BlockBar(block: block, ftp: ftp, maxWatts: maxWatts, scale: scale,
                 isSelected: selectedID == block.id,
                 onSelect: { selectedID = block.id },
                 onUpdate: { updated in
                     selectedID = updated.id
                     onUpdate(updated)
                 },
                 onDragChanged: { onDragChanged(.existing(block.id), $0) },
                 onDragEnded: onDragEnded)
            .opacity(draggedID == block.id ? 0.35 : 1)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: EditorSpace.coordinateSpace) },
                              action: measure(block.id, isRepeat: false, depth: depth))
    }

    /// Bloc ou répétition ; récursif pour les répétitions imbriquées (d'où `AnyView`).
    private func element(_ block: WorkoutBlock, depth: Int, scale: CGFloat) -> AnyView {
        block.kind == .repeats ? AnyView(repeatGroup(block, depth: depth, scale: scale))
                               : AnyView(bar(block, depth: depth, scale: scale))
    }

    private func repeatGroup(_ block: WorkoutBlock, depth: Int, scale: CGFloat) -> some View {
        RepeatGroup(block: block, depth: depth, isSelected: selectedID == block.id,
                    isDropTarget: drag?.target == .intoRepeat(block.id),
                    onSelect: { selectedID = block.id },
                    onChangeCount: { onChangeCount(block.id, $0) },
                    onDragChanged: { onDragChanged(.existing(block.id), $0) },
                    onDragEnded: onDragEnded) {
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(block.blocks) { child in element(child, depth: depth + 1, scale: scale) }
                if block.blocks.isEmpty {
                    Text("Glisse un bloc ici")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, height: 60)
                }
            }
        }
        .opacity(draggedID == block.id ? 0.35 : 1)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: EditorSpace.coordinateSpace) },
                          action: measure(block.id, isRepeat: true, depth: depth))
    }
}

/// Geste de déplacement d'un bloc, mesuré dans le repère de l'éditeur.
@MainActor
private func moveGesture(onChanged: @escaping (CGPoint) -> Void,
                         onEnded: @escaping (CGPoint) -> Void) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: EditorSpace.coordinateSpace)
        .onChanged { onChanged($0.location) }
        .onEnded { onEnded($0.location) }
}

// MARK: - Barre d'un bloc

private struct BlockBar: View {
    let block: WorkoutBlock
    let ftp: Int
    let maxWatts: Double
    /// Points par seconde (pour convertir un glissement horizontal en durée).
    let scale: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onUpdate: (WorkoutBlock) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    /// Valeurs provisoires pendant un redimensionnement (validées au relâchement).
    @State private var draftDuration: TimeInterval?
    @State private var draftStart: Double?
    @State private var draftEnd: Double?

    private static let handle: CGFloat = 10
    private var height: CGFloat { BlockTimeline.barHeight }

    private var duration: TimeInterval { draftDuration ?? block.duration }
    private var startWatts: Double { draftStart ?? block.target.watts(ftp: ftp) }
    private var endWatts: Double {
        draftEnd ?? (block.kind == .ramp ? block.endTarget.watts(ftp: ftp) : startWatts)
    }
    private var width: CGFloat { max(duration * scale, BlockTimeline.minBarWidth) }
    private var isResizing: Bool { draftDuration != nil || draftStart != nil || draftEnd != nil }

    var body: some View {
        let shape = RampShape(start: startWatts / maxWatts, end: endWatts / maxWatts)
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Color.clear
                shape
                    .fill(LinearGradient(colors: [zoneColor(startWatts), zoneColor(endWatts)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(shape.stroke(isSelected ? Color.primary : .clear, lineWidth: 2.5))
            }
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) { resizeHandles }

            // Hauteurs fixes : un libellé rétréci ne doit pas décaler la barre verticalement.
            Text(Format.duration(duration))
                .font(.callout.monospacedDigit().weight(isSelected || isResizing ? .bold : .regular))
                .frame(height: 18)
            Text(powerLabel)
                .font(.caption.monospacedDigit().weight(isResizing ? .bold : .regular))
                .foregroundStyle(isResizing ? .primary : .secondary)
                .frame(height: 15)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(moveGesture(onChanged: onDragChanged, onEnded: onDragEnded))
        .help("Clique pour modifier · glisse pour déplacer · tire le bord droit (durée) ou le haut (puissance)")
    }

    // MARK: - Poignées de redimensionnement

    @ViewBuilder private var resizeHandles: some View {
        let h = Self.handle
        ZStack(alignment: .topLeading) {
            // Haut : puissance. Une rampe a deux poignées (début à gauche, fin à droite).
            if block.kind == .ramp {
                powerHandle(isEnd: false)
                    .frame(width: max(width / 2 - h, 8), height: h)
                    .offset(x: 0, y: topY(startWatts) - h / 2)
                powerHandle(isEnd: true)
                    .frame(width: max(width / 2 - h, 8), height: h)
                    .offset(x: width / 2, y: topY(endWatts) - h / 2)
            } else {
                powerHandle(isEnd: false)
                    .frame(width: max(width - h, 8), height: h)
                    .offset(x: 0, y: topY(startWatts) - h / 2)
            }
            // Bord droit : durée.
            durationHandle
                .frame(width: h, height: height)
                .offset(x: width - h / 2)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    private func topY(_ watts: Double) -> CGFloat {
        height - height * CGFloat(min(max(watts / maxWatts, 0.04), 1))
    }

    // Les gestes sont mesurés dans le repère de la fenêtre : la poignée se déplace avec
    // le bloc pendant le redimensionnement, ce qui ferait trembler une mesure locale.
    private var durationHandle: some View {
        HandleArea()
            .pointerStyle(.frameResize(position: .trailing))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        guard scale > 0 else { return }
                        let raw = block.duration + value.translation.width / scale
                        draftDuration = max((raw / 15).rounded() * 15, 15)   // pas de 15 s
                    }
                    .onEnded { _ in commit() })
    }

    private func powerHandle(isEnd: Bool) -> some View {
        HandleArea()
            .pointerStyle(.frameResize(position: .top))
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = isEnd ? (block.kind == .ramp ? block.endTarget.watts(ftp: ftp) : 0)
                                         : block.target.watts(ftp: ftp)
                        let raw = base - Double(value.translation.height / height) * maxWatts
                        let watts = min(max((raw / 5).rounded() * 5, 0), 2000)   // pas de 5 W
                        if isEnd { draftEnd = watts } else { draftStart = watts }
                    }
                    .onEnded { _ in commit() })
    }

    /// Applique le redimensionnement au bloc (cibles enregistrées en watts).
    private func commit() {
        var updated = block
        if let d = draftDuration { updated.duration = d }
        if let w = draftStart {
            updated.target = .watts(Int(w.rounded()))
            if block.kind != .ramp { updated.endTarget = updated.target }
        }
        if let w = draftEnd { updated.endTarget = .watts(Int(w.rounded())) }
        draftDuration = nil
        draftStart = nil
        draftEnd = nil
        onUpdate(updated)
    }

    private func zoneColor(_ watts: Double) -> Color { PowerZone(watts: watts, ftp: ftp).color }

    private var powerLabel: String {
        block.kind == .ramp ? "\(Int(startWatts.rounded()))→\(Int(endWatts.rounded())) W"
                            : "\(Int(startWatts.rounded())) W"
    }
}

/// Zone de prise invisible sur un bord du bloc.
private struct HandleArea: View {
    var body: some View {
        Rectangle().fill(Color.clear).contentShape(Rectangle())
    }
}

/// Ligne horizontale (pour le trait pointillé de la FTP).
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// Rectangle (constant) ou trapèze (rampe) aux coins arrondis, hauteurs en fraction de la zone.
struct RampShape: Shape {
    var start: Double
    var end: Double
    var cornerRadius: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let s = rect.height * min(max(start, 0.04), 1)
        let e = rect.height * min(max(end, 0.04), 1)
        let r = min(cornerRadius, rect.width / 3, s / 2, e / 2)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let topLeft = CGPoint(x: rect.minX, y: rect.maxY - s)
        let topRight = CGPoint(x: rect.maxX, y: rect.maxY - e)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: r)
        p.addArc(tangent1End: topLeft, tangent2End: topRight, radius: r)
        p.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: r)
        p.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: r)
        p.closeSubpath()
        return p
    }
}

// MARK: - Groupe de répétition

private struct RepeatGroup<Content: View>: View {
    let block: WorkoutBlock
    /// Niveau d'imbrication (0 = répétition de premier niveau).
    let depth: Int
    let isSelected: Bool
    /// Un bloc glissé sera déposé dans cette répétition.
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onChangeCount: (Int) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "repeat")
                Text("× \(block.count)").font(.headline.monospacedDigit())
                Spacer(minLength: 4)
                Button { onChangeCount(block.count - 1) } label: { Image(systemName: "minus.circle") }
                    .disabled(block.count <= 1)
                Button { onChangeCount(block.count + 1) } label: { Image(systemName: "plus.circle") }
            }
            .buttonStyle(.borderless)
            .lineLimit(1)
            content
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        // Le cadre descend sous les libellés sans occuper de place : toutes les barres,
        // quel que soit leur niveau d'imbrication, restent sur la même ligne de base.
        .background(frame.fill(Color.primary.opacity(0.06)).padding(.bottom, -bottomOverflow))
        .overlay(frame
            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 2, dash: isDropTarget ? [] : [5, 4]))
            .padding(.bottom, -bottomOverflow))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .gesture(moveGesture(onChanged: onDragChanged, onEnded: onDragEnded))
    }

    private var frame: RoundedRectangle { RoundedRectangle(cornerRadius: 10) }

    /// Débordement du cadre sous les barres, plus faible pour les niveaux imbriqués.
    private var bottomOverflow: CGFloat { max(8 - CGFloat(depth) * 3, 2) }

    private var borderColor: Color {
        if isDropTarget || isSelected { return .accentColor }
        return .secondary.opacity(0.5)
    }
}

// MARK: - Séance vide

/// Zone affichée quand la séance ne contient encore aucun bloc.
private struct EmptyDropZone: View {
    let isTargeted: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(isTargeted ? Color.accentColor : .secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .overlay {
                Text("Ajoute un premier bloc").font(.callout).foregroundStyle(.secondary)
            }
            .frame(width: 220, height: BlockTimeline.barHeight)
            .padding(.bottom, 38)
    }
}
