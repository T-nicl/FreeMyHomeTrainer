import Foundation

/// Opérations d'édition sur l'arbre de blocs (un seul niveau de répétition).
extension Array where Element == WorkoutBlock {
    func find(_ id: WorkoutBlock.ID) -> WorkoutBlock? {
        for b in self {
            if b.id == id { return b }
            if let found = b.blocks.find(id) { return found }
        }
        return nil
    }

    func parentID(of id: WorkoutBlock.ID) -> WorkoutBlock.ID? {
        for b in self {
            if b.blocks.contains(where: { $0.id == id }) { return b.id }
            if let p = b.blocks.parentID(of: id) { return p }
        }
        return nil
    }

    /// Applique `body` à la liste qui contient le bloc `id`, avec son index.
    @discardableResult
    private mutating func withContainer<R>(of id: WorkoutBlock.ID,
                                           _ body: (inout [WorkoutBlock], Int) -> R) -> R? {
        if let i = firstIndex(where: { $0.id == id }) { return body(&self, i) }
        for i in indices {
            if let r = self[i].blocks.withContainer(of: id, body) { return r }
        }
        return nil
    }

    mutating func replace(_ id: WorkoutBlock.ID, with block: WorkoutBlock) {
        withContainer(of: id) { list, i in list[i] = block }
    }

    mutating func remove(_ id: WorkoutBlock.ID) {
        withContainer(of: id) { list, i in list.remove(at: i) }
    }

    mutating func insert(_ block: WorkoutBlock, relativeTo id: WorkoutBlock.ID, after: Bool) {
        withContainer(of: id) { list, i in list.insert(block, at: after ? i + 1 : i) }
    }

    mutating func move(_ id: WorkoutBlock.ID, by offset: Int) {
        withContainer(of: id) { list, i in
            let j = i + offset
            guard list.indices.contains(j) else { return }
            list.swapAt(i, j)
        }
    }

    /// Duplique le bloc (avec de nouveaux identifiants) et renvoie l'id de la copie.
    mutating func duplicate(_ id: WorkoutBlock.ID) -> WorkoutBlock.ID? {
        withContainer(of: id) { list, i in
            let copy = list[i].withNewIDs()
            list.insert(copy, at: i + 1)
            return copy.id
        }
    }

    mutating func appendChild(_ child: WorkoutBlock, toRepeat id: WorkoutBlock.ID) {
        withContainer(of: id) { list, i in list[i].blocks.append(child) }
    }

    // MARK: - Glisser-déposer

    /// Vrai si `block` peut être placé à côté de `targetID` : pas de répétition imbriquée,
    /// pas de bloc déposé sur lui-même ni dans ses propres enfants.
    func canPlace(_ block: WorkoutBlock, nextTo targetID: WorkoutBlock.ID) -> Bool {
        guard block.id != targetID, block.blocks.find(targetID) == nil else { return false }
        return block.kind != .repeats || parentID(of: targetID) == nil
    }

    /// Déplace le bloc `id` juste avant ou après `targetID` (éventuellement dans une autre répétition).
    @discardableResult
    mutating func moveBlock(_ id: WorkoutBlock.ID, relativeTo targetID: WorkoutBlock.ID, after: Bool) -> Bool {
        guard let moving = find(id), canPlace(moving, nextTo: targetID) else { return false }
        remove(id)
        insert(moving, relativeTo: targetID, after: after)
        return true
    }

    /// Déplace le bloc `id` à la fin de la répétition `repeatID`.
    @discardableResult
    mutating func moveBlock(_ id: WorkoutBlock.ID, intoRepeat repeatID: WorkoutBlock.ID) -> Bool {
        guard let moving = find(id), moving.kind != .repeats, id != repeatID else { return false }
        remove(id)
        appendChild(moving, toRepeat: repeatID)
        return true
    }

    /// Déplace le bloc `id` à la fin de la séance.
    mutating func moveBlockToEnd(_ id: WorkoutBlock.ID) {
        guard let moving = find(id) else { return }
        remove(id)
        append(moving)
    }
}

extension WorkoutBlock {
    func withNewIDs() -> WorkoutBlock {
        var copy = self
        copy.id = UUID()
        copy.blocks = blocks.map { $0.withNewIDs() }
        return copy
    }

    /// Durée affichée dans l'éditeur : une seule itération pour une répétition.
    var displayDuration: TimeInterval {
        kind == .repeats ? blocks.reduce(0) { $0 + $1.duration } : duration
    }
}
