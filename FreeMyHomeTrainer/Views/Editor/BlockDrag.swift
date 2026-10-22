import SwiftUI

// Glisser-déposer interne à l'éditeur.
//
// On n'utilise pas le glisser-déposer système (NSItemProvider) : prévu pour glisser entre
// applications, il est asynchrone, anime sa propre image flottante et signale mal la fin
// d'un glisser. Ici, l'éditeur suit le pointeur avec un DragGesture, connaît la position de
// chaque bloc et calcule à chaque instant un unique emplacement d'arrivée.

/// Où déposer un bloc glissé dans la frise.
enum BlockDropTarget: Equatable {
    case relative(WorkoutBlock.ID, after: Bool)
    case intoRepeat(WorkoutBlock.ID)
    case end
}

/// Contenu glissé : un bloc existant ou un nouveau bloc venant de la palette.
enum BlockDragPayload: Equatable {
    case existing(WorkoutBlock.ID)
    case new(WorkoutBlock.Kind)
}

/// Glisser en cours, dans le repère de l'éditeur.
struct BlockDrag: Equatable {
    var payload: BlockDragPayload
    var location: CGPoint
    var target: BlockDropTarget?
}

/// Repère commun à l'éditeur, à la frise et à la palette.
enum EditorSpace {
    static let name = "workoutEditor"
    static var coordinateSpace: NamedCoordinateSpace { .named(name) }
}

/// Positions mesurées des éléments de la frise. Volontairement non observé : écrit pendant
/// la mise en page, lu seulement pendant un glisser (pas de cycle de rafraîchissement).
@MainActor
final class BlockFrames {
    struct Item: Equatable {
        var rect: CGRect
        var isRepeat: Bool
        /// 0 = élément de premier niveau.
        var depth: Int
    }

    var items: [WorkoutBlock.ID: Item] = [:]
    var timeline: CGRect = .zero
}

enum BlockDropResolver {
    /// Largeur des bords d'une répétition qui signifient « avant / après » plutôt que « dedans ».
    static let repeatEdge: CGFloat = 18

    /// Emplacement d'arrivée pour un pointeur en `point`, ou nil si le dépôt n'aurait pas de sens
    /// (hors de la frise, sur le bloc lui-même ou dans ses propres sous-blocs).
    static func target(at point: CGPoint, payload: BlockDragPayload, blocks: [WorkoutBlock],
                       items: [WorkoutBlock.ID: BlockFrames.Item], timeline: CGRect) -> BlockDropTarget? {
        guard timeline.contains(point) else { return nil }
        guard !blocks.isEmpty else { return .end }
        let items = items.filter { blocks.find($0.key) != nil }

        func valid(_ target: BlockDropTarget) -> BlockDropTarget? {
            guard case .existing(let movingID) = payload else { return target }
            guard let moving = blocks.find(movingID) else { return nil }
            switch target {
            case .relative(let id, _): return blocks.canPlace(moving, nextTo: id) ? target : nil
            case .intoRepeat(let id): return id != movingID && moving.blocks.find(id) == nil ? target : nil
            case .end: return target
            }
        }

        // 1. Sur un bloc : avant ou après selon la moitié survolée.
        if let leaf = items.first(where: { !$0.value.isRepeat && $0.value.rect.contains(point) }) {
            return valid(.relative(leaf.key, after: point.x > leaf.value.rect.midX))
        }
        // 2. Sur une répétition (la plus imbriquée) : bords = avant / après, milieu = dedans.
        if let group = items.filter({ $0.value.isRepeat && $0.value.rect.contains(point) })
            .max(by: { $0.value.depth < $1.value.depth }) {
            let r = group.value.rect
            if point.x < r.minX + repeatEdge { return valid(.relative(group.key, after: false)) }
            if point.x > r.maxX - repeatEdge { return valid(.relative(group.key, after: true)) }
            return valid(.intoRepeat(group.key))
        }
        // 3. Ailleurs dans la frise (entre deux blocs, au-dessus…) : d'après la position horizontale.
        let top = items.filter { $0.value.depth == 0 }.sorted { $0.value.rect.minX < $1.value.rect.minX }
        if let next = top.first(where: { point.x < $0.value.rect.midX }) {
            return valid(.relative(next.key, after: false))
        }
        if let last = top.last { return valid(.relative(last.key, after: true)) }
        return .end
    }
}

/// Repère d'insertion et étiquette qui suit le pointeur, dessinés par-dessus l'éditeur.
struct BlockDragOverlay: View {
    let drag: BlockDrag
    let frames: BlockFrames
    let blocks: [WorkoutBlock]
    let ftp: Int

    /// Hauteur des libellés sous chaque barre (durée + puissance).
    static let labelsHeight: CGFloat = 37

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let marker = markerRect {
                Capsule()
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: marker.width, height: marker.height)
                    .position(x: marker.midX, y: marker.midY)
            }
            ghost
                .position(x: drag.location.x, y: drag.location.y - 30)
        }
        .allowsHitTesting(false)
    }

    /// Trait vertical au milieu de l'espace entre deux éléments.
    private var markerRect: CGRect? {
        guard case .relative(let id, let after) = drag.target, let item = frames.items[id] else { return nil }
        let r = item.rect
        let x = after ? r.maxX + BlockTimeline.gap / 2 : r.minX - BlockTimeline.gap / 2
        let top = r.minY + 12
        let bottom = r.maxY - Self.labelsHeight - 12
        return CGRect(x: x - 1, y: top, width: 2, height: max(bottom - top, 20))
    }

    private var ghost: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title).monospacedDigit()
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .opacity(drag.target == nil ? 0.55 : 1)
    }

    private var block: WorkoutBlock? {
        if case .existing(let id) = drag.payload { return blocks.find(id) }
        return nil
    }

    private var kind: WorkoutBlock.Kind {
        switch drag.payload {
        case .existing: block?.kind ?? .steady
        case .new(let kind): kind
        }
    }

    private var icon: String { kind == .repeats ? "repeat" : "rectangle.fill" }

    private var title: String {
        guard let block else { return kind == .repeats ? "Répétition" : "Bloc" }
        switch block.kind {
        case .repeats: return "× \(block.count) · \(Format.duration(block.totalDuration))"
        case .steady, .ramp:
            return "\(Format.duration(block.duration)) · \(Int(block.target.watts(ftp: ftp).rounded())) W"
        }
    }

    private var color: Color {
        guard let block, block.kind != .repeats else { return .gray }
        return PowerZone(watts: block.target.watts(ftp: ftp), ftp: ftp).color
    }
}
