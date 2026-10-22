import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Où déposer un bloc glissé dans la frise.
enum BlockDropTarget: Equatable {
    case relative(WorkoutBlock.ID, after: Bool)
    case intoRepeat(WorkoutBlock.ID)
    case end
}

/// Contenu glissé : un bloc existant ou un nouveau bloc venant de la palette.
enum BlockDragPayload {
    case existing(WorkoutBlock.ID)
    case new(WorkoutBlock.Kind)

    private static let existingPrefix = "fmht-block:"
    private static let newPrefix = "fmht-new:"

    var string: String {
        switch self {
        case .existing(let id): Self.existingPrefix + id.uuidString
        case .new(let kind): Self.newPrefix + kind.rawValue
        }
    }

    init?(_ string: String) {
        if string.hasPrefix(Self.existingPrefix),
           let id = UUID(uuidString: String(string.dropFirst(Self.existingPrefix.count))) {
            self = .existing(id)
        } else if string.hasPrefix(Self.newPrefix),
                  let kind = WorkoutBlock.Kind(rawValue: String(string.dropFirst(Self.newPrefix.count))) {
            self = .new(kind)
        } else {
            return nil
        }
    }

    func itemProvider() -> NSItemProvider { NSItemProvider(object: string as NSString) }
}

/// Frise de la séance : chaque bloc est une barre (largeur = durée, hauteur = puissance).
/// Clic pour sélectionner, glisser pour déplacer.
struct BlockTimeline: View {
    let blocks: [WorkoutBlock]
    let ftp: Int
    @Binding var selectedID: WorkoutBlock.ID?
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    let onChangeCount: (WorkoutBlock.ID, Int) -> Void
    /// Bloc modifié en tirant sur ses bords.
    let onUpdate: (WorkoutBlock) -> Void

    /// Emplacement de dépôt survolé, partagé par toute la frise : un seul repère à la fois,
    /// effacé au dépôt, à l'annulation du glisser ou dès que la séance change.
    @State private var dropHover: (id: WorkoutBlock.ID, side: HoverSide)?

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
                    if blocks.isEmpty { EmptyDropZone(onDrop: onDrop) }
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
        .onChange(of: blocks) { dropHover = nil }
        .task(id: dropHover != nil) { await clearMarkerWhenMouseReleased() }
    }

    /// macOS ne signale pas toujours la fin d'un glisser (selon l'endroit où l'on lâche).
    /// Tant qu'un repère est affiché, on vérifie donc le bouton de la souris : relâché,
    /// le glisser est forcément terminé et le repère disparaît.
    private func clearMarkerWhenMouseReleased() async {
        while dropHover != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            if NSEvent.pressedMouseButtons & 1 == 0 { dropHover = nil }
        }
    }

    private func hoverBinding(for id: WorkoutBlock.ID) -> Binding<HoverSide?> {
        Binding(get: { dropHover?.id == id ? dropHover?.side : nil },
                set: { side in
                    if let side {
                        dropHover = (id, side)
                    } else if dropHover?.id == id {
                        dropHover = nil
                    }
                })
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

    private func bar(_ block: WorkoutBlock, scale: CGFloat) -> some View {
        BlockBar(block: block, ftp: ftp, maxWatts: maxWatts, scale: scale,
                 isSelected: selectedID == block.id,
                 hover: hoverBinding(for: block.id),
                 clearHover: { dropHover = nil },
                 onSelect: { selectedID = block.id },
                 onUpdate: { updated in
                     selectedID = updated.id
                     onUpdate(updated)
                 },
                 onDrop: onDrop)
    }

    /// Bloc ou répétition ; récursif pour les répétitions imbriquées (d'où `AnyView`).
    private func element(_ block: WorkoutBlock, depth: Int, scale: CGFloat) -> AnyView {
        block.kind == .repeats ? AnyView(repeatGroup(block, depth: depth, scale: scale))
                               : AnyView(bar(block, scale: scale))
    }

    private func repeatGroup(_ block: WorkoutBlock, depth: Int, scale: CGFloat) -> some View {
        RepeatGroup(block: block, depth: depth, isSelected: selectedID == block.id,
                    hover: hoverBinding(for: block.id),
                    clearHover: { dropHover = nil },
                    onSelect: { selectedID = block.id },
                    onChangeCount: { onChangeCount(block.id, $0) },
                    onDrop: onDrop) {
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
    }
}

// MARK: - Barre d'un bloc

private enum HoverSide { case before, after, inside }

private struct BlockBar: View {
    let block: WorkoutBlock
    let ftp: Int
    let maxWatts: Double
    /// Points par seconde (pour convertir un glissement horizontal en durée).
    let scale: CGFloat
    let isSelected: Bool
    @Binding var hover: HoverSide?
    let clearHover: () -> Void
    let onSelect: () -> Void
    let onUpdate: (WorkoutBlock) -> Void
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
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
            .overlay(alignment: hover == .after ? .trailing : .leading) {
                if hover == .before || hover == .after { InsertionMarker(after: hover == .after) }
            }

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
        .onDrag { BlockDragPayload.existing(block.id).itemProvider() }
        .onDrop(of: [.plainText], delegate: SideDropDelegate(
            width: width, hover: $hover,
            target: { side in .relative(block.id, after: side == .after) },
            perform: onDrop, onFinish: clearHover))
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

/// Repère discret indiquant où le bloc glissé sera déposé.
/// « Après A » et « avant B » désignent le même emplacement : le repère est donc décalé
/// au milieu de l'espace entre les deux blocs, pour apparaître toujours au même endroit.
private struct InsertionMarker: View {
    let after: Bool
    private static let width: CGFloat = 2

    var body: some View {
        Capsule()
            .fill(Color.gray.opacity(0.6))
            .frame(width: Self.width)
            .padding(.vertical, 12)
            .offset(x: (BlockTimeline.gap + Self.width) / 2 * (after ? 1 : -1))
    }
}

// MARK: - Groupe de répétition

private struct RepeatGroup<Content: View>: View {
    let block: WorkoutBlock
    /// Niveau d'imbrication (0 = répétition de premier niveau).
    let depth: Int
    let isSelected: Bool
    @Binding var hover: HoverSide?
    let clearHover: () -> Void
    let onSelect: () -> Void
    let onChangeCount: (Int) -> Void
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    @ViewBuilder let content: Content
    @State private var width: CGFloat = 200

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
            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 2, dash: hover == .inside ? [] : [5, 4]))
            .padding(.bottom, -bottomOverflow))
        .overlay(alignment: hover == .after ? .trailing : .leading) {
            if hover == .before || hover == .after { InsertionMarker(after: hover == .after) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onDrag { BlockDragPayload.existing(block.id).itemProvider() }
        .onDrop(of: [.plainText], delegate: SideDropDelegate(
            width: width, hover: $hover, edge: 18,
            target: { side in
                side == .inside ? .intoRepeat(block.id) : .relative(block.id, after: side == .after)
            },
            perform: onDrop, onFinish: clearHover))
    }

    private var frame: RoundedRectangle { RoundedRectangle(cornerRadius: 10) }

    /// Débordement du cadre sous les barres, plus faible pour les niveaux imbriqués.
    private var bottomOverflow: CGFloat { max(8 - CGFloat(depth) * 3, 2) }

    private var borderColor: Color {
        if hover == .inside || isSelected { return .accentColor }
        return .secondary.opacity(0.5)
    }
}

// MARK: - Séance vide

/// Zone de dépôt affichée seulement quand la séance ne contient encore aucun bloc.
private struct EmptyDropZone: View {
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    @State private var hover: HoverSide?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(hover != nil ? Color.accentColor : .secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .overlay {
                Text("Ajoute un premier bloc").font(.callout).foregroundStyle(.secondary)
            }
            .frame(width: 220, height: BlockTimeline.barHeight)
            .padding(.bottom, 38)
            .onDrop(of: [.plainText], delegate: SideDropDelegate(
                width: 220, hover: $hover, target: { _ in .end }, perform: onDrop))
            .task(id: hover != nil) {
                while hover != nil, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    if NSEvent.pressedMouseButtons & 1 == 0 { hover = nil }
                }
            }
    }
}

// MARK: - Dépôt

/// Déduit l'emplacement de dépôt (avant / après / dedans) de la position du pointeur.
private struct SideDropDelegate: DropDelegate {
    let width: CGFloat
    @Binding var hover: HoverSide?
    /// Largeur des bords « avant / après » ; 0 = moitié gauche / moitié droite.
    var edge: CGFloat = 0
    let target: (HoverSide) -> BlockDropTarget
    let perform: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    /// Appelé à la fin d'un dépôt : efface tous les repères de la frise, pas seulement le sien
    /// (dans une répétition, le bloc et la répétition sont deux zones superposées).
    var onFinish: () -> Void = {}

    private func side(_ info: DropInfo) -> HoverSide {
        let x = info.location.x
        if edge == 0 { return x < width / 2 ? .before : .after }
        if x < edge { return .before }
        if x > width - edge { return .after }
        return .inside
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover = side(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { hover = nil }

    func performDrop(info: DropInfo) -> Bool {
        let destination = target(side(info))
        hover = nil
        onFinish()
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let perform = self.perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString, let payload = BlockDragPayload(string as String) else { return }
            Task { @MainActor in perform(payload, destination) }
        }
        return true
    }
}
