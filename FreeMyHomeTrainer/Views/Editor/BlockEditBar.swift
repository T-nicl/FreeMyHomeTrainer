import SwiftUI

/// Barre d'édition du bloc sélectionné, affichée sous la frise.
struct BlockEditBar: View {
    @Binding var block: WorkoutBlock
    let ftp: Int
    let isNested: Bool
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onAddChild: (WorkoutBlock) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                if block.kind == .repeats {
                    Label("Répétition", systemImage: "repeat").font(.headline)
                    Stepper(value: $block.count, in: 1...50) {
                        Text("\(block.count) fois").monospacedDigit()
                    }
                    .fixedSize()
                } else {
                    Picker("Type", selection: kindBinding) {
                        Text("Constant").tag(WorkoutBlock.Kind.steady)
                        Text("Rampe").tag(WorkoutBlock.Kind.ramp)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    field("Durée") { DurationField(duration: $block.duration) }
                }
                Spacer(minLength: 0)
                Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }
                    .help("Dupliquer (⌘D)")
                    .keyboardShortcut("d", modifiers: .command)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Supprimer (⌫)")
            }

            HStack(spacing: 16) {
                switch block.kind {
                case .steady:
                    field("Puissance") { PowerField(target: $block.target, ftp: ftp) }
                case .ramp:
                    field("De") { PowerField(target: $block.target, ftp: ftp) }
                    field("à") { PowerField(target: $block.endTarget, ftp: ftp) }
                case .repeats:
                    Text("Ajouter dans la répétition :").foregroundStyle(.secondary)
                    Button("Constant") { onAddChild(.steady(300, .ftpPercent(90))) }
                    Button("Rampe") { onAddChild(.ramp(300, from: .ftpPercent(60), to: .ftpPercent(90))) }
                    Text("Durée totale \(Format.duration(block.totalDuration))")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .lineLimit(1)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            content()
        }
        .fixedSize()
    }

    /// Changer de type conserve la durée et la cible.
    private var kindBinding: Binding<WorkoutBlock.Kind> {
        Binding(get: { block.kind }, set: { kind in
            guard kind != block.kind else { return }
            if kind == .ramp { block.endTarget = block.target }
            block.kind = kind
        })
    }
}

/// Durée saisie en « mm:ss » (ou « h:mm:ss », ou des minutes seules), avec flèches ±30 s.
struct DurationField: View {
    @Binding var duration: TimeInterval

    var body: some View {
        HStack(spacing: 2) {
            TextField("mm:ss", value: $duration, format: DurationFormat())
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Stepper("", onIncrement: { duration += 30 }, onDecrement: { duration = max(duration - 30, 10) })
                .labelsHidden()
        }
    }
}

/// Valeur de puissance + unité (W ou % FTP), avec l'équivalent dans l'autre unité.
struct PowerField: View {
    @Binding var target: Target
    let ftp: Int

    private enum Unit: Hashable { case watts, percent }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: valueBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            Stepper("", onIncrement: { step(+1) }, onDecrement: { step(-1) }).labelsHidden()
            Picker("Unité", selection: unitBinding) {
                Text("W").tag(Unit.watts)
                Text("% FTP").tag(Unit.percent)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            let watts = target.watts(ftp: ftp)
            Circle().fill(PowerZone(watts: watts, ftp: ftp).color).frame(width: 9, height: 9)
            Text(equivalent(watts)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var unit: Unit {
        if case .watts = target { .watts } else { .percent }
    }

    private func equivalent(_ watts: Double) -> String {
        switch target {
        case .watts: ftp > 0 ? "\(Int((watts / Double(ftp) * 100).rounded())) %" : ""
        case .ftpPercent: "\(Int(watts.rounded())) W"
        }
    }

    private var unitBinding: Binding<Unit> {
        Binding(get: { unit }, set: { newUnit in
            guard newUnit != unit else { return }
            let watts = target.watts(ftp: ftp)
            target = newUnit == .watts
                ? .watts(Int(watts.rounded()))
                : .ftpPercent(ftp > 0 ? Int((watts / Double(ftp) * 100).rounded()) : 100)
        })
    }

    private var valueBinding: Binding<Int> {
        Binding(get: {
            switch target {
            case .watts(let w): w
            case .ftpPercent(let p): p
            }
        }, set: { v in
            let v = max(v, 0)
            target = unit == .watts ? .watts(v) : .ftpPercent(v)
        })
    }

    private func step(_ direction: Int) {
        switch target {
        case .watts(let w): target = .watts(max(w + 5 * direction, 0))
        case .ftpPercent(let p): target = .ftpPercent(max(p + direction, 0))
        }
    }
}

/// Format « m:ss » / « h:mm:ss » pour les champs de durée.
struct DurationFormat: ParseableFormatStyle {
    var parseStrategy: DurationParseStrategy { DurationParseStrategy() }

    func format(_ value: TimeInterval) -> String { Format.clock(value) }
}

struct DurationParseStrategy: ParseStrategy {
    struct InvalidDuration: Error {}

    /// « 10 » = 10 min, « 1:30 » = 1 min 30, « 1:00:00 » = 1 h. Accepte aussi « 10'30 ».
    func parse(_ value: String) throws -> TimeInterval {
        let parts = value.replacingOccurrences(of: "'", with: ":")
            .replacingOccurrences(of: "\"", with: "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let numbers = try parts.map { part -> Int in
            if part.isEmpty { return 0 }
            guard let n = Int(part), n >= 0 else { throw InvalidDuration() }
            return n
        }
        let seconds: Int
        switch numbers.count {
        case 1: seconds = numbers[0] * 60
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: throw InvalidDuration()
        }
        guard seconds > 0 else { throw InvalidDuration() }
        return TimeInterval(seconds)
    }
}
