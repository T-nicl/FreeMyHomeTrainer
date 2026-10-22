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

    static let barHeight: CGFloat = 150
    static let minBarWidth: CGFloat = 54
    private static let groupPadding: CGFloat = 8
    private static let endZoneWidth: CGFloat = 64

    var body: some View {
        GeometryReader { geo in
            let scale = pointsPerSecond(width: geo.size.width)
            ScrollView(.horizontal) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(blocks) { block in
                        if block.kind == .repeats {
                            repeatGroup(block, scale: scale)
                        } else {
                            bar(block, scale: scale)
                                .padding(.bottom, Self.groupPadding)
                        }
                    }
                    EndDropZone(isEmpty: blocks.isEmpty, onDrop: onDrop)
                        .padding(.bottom, Self.groupPadding)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .bottomLeading)
                .contentShape(Rectangle())
                .onTapGesture { selectedID = nil }
            }
        }
        .frame(height: Self.barHeight + 100)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Échelles

    private func pointsPerSecond(width: CGFloat) -> CGFloat {
        let total = blocks.reduce(0) { $0 + $1.displayDuration }
        guard total > 0 else { return 0 }
        let groups = CGFloat(blocks.filter { $0.kind == .repeats }.count)
        let overhead = 24 + Self.endZoneWidth + CGFloat(blocks.count) * 4 + groups * (Self.groupPadding * 2 + 8)
        return max((width - overhead) / total, 0)
    }

    private var maxWatts: Double {
        let leaves = blocks.flatMap { $0.kind == .repeats ? $0.blocks : [$0] }
        let peak = leaves.map { max($0.target.watts(ftp: ftp), $0.endTarget.watts(ftp: ftp)) }.max() ?? 0
        return max(peak * 1.08, Double(ftp) * 1.2, 1)
    }

    // MARK: - Éléments

    private func bar(_ block: WorkoutBlock, scale: CGFloat) -> some View {
        BlockBar(block: block, ftp: ftp, maxWatts: maxWatts,
                 width: max(block.duration * scale, Self.minBarWidth),
                 isSelected: selectedID == block.id,
                 onSelect: { selectedID = block.id },
                 onDrop: onDrop)
    }

    private func repeatGroup(_ block: WorkoutBlock, scale: CGFloat) -> some View {
        RepeatGroup(block: block, isSelected: selectedID == block.id,
                    onSelect: { selectedID = block.id },
                    onChangeCount: { onChangeCount(block.id, $0) },
                    onDrop: onDrop) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(block.blocks) { child in bar(child, scale: scale) }
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
    let width: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    @State private var hover: HoverSide?

    var body: some View {
        let start = block.target.watts(ftp: ftp)
        let end = block.kind == .ramp ? block.endTarget.watts(ftp: ftp) : start
        let shape = RampShape(start: start / maxWatts, end: end / maxWatts)
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Color.clear
                shape
                    .fill(LinearGradient(colors: [zoneColor(start), zoneColor(end)],
                                         startPoint: .leading, endPoint: .trailing))
                    .overlay(shape.stroke(isSelected ? Color.primary : .clear, lineWidth: 2.5))
            }
            .frame(width: width, height: BlockTimeline.barHeight)
            .overlay(alignment: hover == .after ? .trailing : .leading) {
                if hover == .before || hover == .after { InsertionMarker() }
            }

            // Hauteurs fixes : un libellé rétréci ne doit pas décaler la barre verticalement.
            Text(Format.duration(block.duration))
                .font(.callout.monospacedDigit().weight(isSelected ? .bold : .regular))
                .frame(height: 18)
            Text(powerLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
            perform: onDrop))
        .help("Clique pour modifier, glisse pour déplacer")
    }

    private func zoneColor(_ watts: Double) -> Color { PowerZone(watts: watts, ftp: ftp).color }

    private var powerLabel: String {
        switch block.kind {
        case .ramp: "\(short(block.target))→\(short(block.endTarget))"
        default: short(block.target)
        }
    }

    private func short(_ t: Target) -> String {
        switch t {
        case .watts(let w): "\(w) W"
        case .ftpPercent(let p): "\(p) %"
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

private struct InsertionMarker: View {
    var body: some View {
        Capsule().fill(Color.accentColor).frame(width: 4).padding(.vertical, -4)
    }
}

// MARK: - Groupe de répétition

private struct RepeatGroup<Content: View>: View {
    let block: WorkoutBlock
    let isSelected: Bool
    let onSelect: () -> Void
    let onChangeCount: (Int) -> Void
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    @ViewBuilder let content: Content
    @State private var hover: HoverSide?
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
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 2, dash: hover == .inside ? [] : [5, 4])))
        .overlay(alignment: hover == .after ? .trailing : .leading) {
            if hover == .before || hover == .after { InsertionMarker() }
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
            perform: onDrop))
    }

    private var borderColor: Color {
        if hover == .inside || isSelected { return .accentColor }
        return .secondary.opacity(0.5)
    }
}

// MARK: - Zone de fin

private struct EndDropZone: View {
    let isEmpty: Bool
    let onDrop: @MainActor (BlockDragPayload, BlockDropTarget) -> Void
    @State private var hover: HoverSide?

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(hover != nil ? Color.accentColor : .secondary.opacity(0.4),
                          style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.title2)
                    if isEmpty { Text("Glisse un bloc ici").font(.caption) }
                }
                .foregroundStyle(.secondary)
            }
            .frame(width: isEmpty ? 200 : 54, height: BlockTimeline.barHeight)
            .padding(.bottom, 38)
            .onDrop(of: [.plainText], delegate: SideDropDelegate(
                width: 54, hover: $hover, target: { _ in .end }, perform: onDrop))
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
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let perform = self.perform
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? NSString, let payload = BlockDragPayload(string as String) else { return }
            Task { @MainActor in perform(payload, destination) }
        }
        return true
    }
}
