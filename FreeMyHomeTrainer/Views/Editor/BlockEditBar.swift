import SwiftUI

/// Barre d'édition du bloc sélectionné, affichée sous la frise.
/// Les lignes passent en colonne quand la place manque (jamais de débordement).
struct BlockEditBar: View {
    @Binding var block: WorkoutBlock
    let ftp: Int
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    let onAddChild: (WorkoutBlock.Kind) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                switch block.kind {
                case .steady, .ramp:
                    adaptive {
                        Picker("Type", selection: kindBinding) {
                            Text("Constant").tag(WorkoutBlock.Kind.steady)
                            Text("Rampe").tag(WorkoutBlock.Kind.ramp)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        field("Durée") { DurationField(duration: $block.duration) }
                    }
                    if block.kind == .steady {
                        field("Puissance") { PowerField(target: $block.target, ftp: ftp) }
                    } else {
                        adaptive {
                            field("De") { PowerField(target: $block.target, ftp: ftp) }
                            field("à") { PowerField(target: $block.endTarget, ftp: ftp) }
                        }
                    }
                case .repeats:
                    adaptive {
                        Label("Répétition", systemImage: "repeat").font(.headline)
                        Stepper(value: $block.count, in: 1...50) {
                            Text("\(block.count) fois").monospacedDigit()
                        }
                        .fixedSize()
                        Text("Durée totale \(Format.duration(block.totalDuration))")
                            .foregroundStyle(.secondary)
                    }
                    adaptive {
                        Text("Ajouter dans la répétition :").foregroundStyle(.secondary)
                        HStack {
                            Button("Bloc") { onAddChild(.steady) }
                            Button("Répétition") { onAddChild(.repeats) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                Button(action: onDuplicate) { Image(systemName: "plus.square.on.square") }
                    .help("Dupliquer (⌘D)")
                    .keyboardShortcut("d", modifiers: .command)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .help("Supprimer (⌫)")
            }
        }
        .lineLimit(1)
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Côte à côte si ça tient, sinon les uns sous les autres.
    private func adaptive(@ViewBuilder _ content: () -> some View) -> some View {
        let items = content()
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { items }
            VStack(alignment: .leading, spacing: 10) { items }
        }
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
            TextField("", value: $duration, format: DurationFormat(), prompt: Text("mm:ss"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
            Stepper("", onIncrement: { duration += 30 }, onDecrement: { duration = max(duration - 30, 10) })
                .labelsHidden()
        }
    }
}

/// Puissance saisie et affichée en watts, avec l'équivalent en % de FTP pour information.
/// Modifier la valeur enregistre toujours la cible en watts.
struct PowerField: View {
    @Binding var target: Target
    let ftp: Int

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: wattsBinding, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            Text("W")
            Stepper("", onIncrement: { step(+5) }, onDecrement: { step(-5) }).labelsHidden()
            Circle().fill(PowerZone(watts: watts, ftp: ftp).color).frame(width: 9, height: 9)
            if ftp > 0 {
                Text("≈ \(Int(safe: watts / Double(ftp) * 100)) % FTP")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var watts: Double { target.watts(ftp: ftp) }

    private var wattsBinding: Binding<Int> {
        Binding(get: { Int(safe: watts) }, set: { target = .watts(min(max($0, 0), WorkoutLimits.maxWatts)) })
    }

    private func step(_ delta: Int) {
        target = .watts(min(max(Int(safe: watts) + delta, 0), WorkoutLimits.maxWatts))
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
            // Au plus 6 chiffres par partie : pas de débordement dans le calcul en secondes.
            guard part.count <= 6, let n = Int(part), n >= 0 else { throw InvalidDuration() }
            return n
        }
        let seconds: Int
        switch numbers.count {
        case 1: seconds = numbers[0] * 60
        case 2: seconds = numbers[0] * 60 + numbers[1]
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: throw InvalidDuration()
        }
        guard seconds > 0, TimeInterval(seconds) <= WorkoutLimits.maxBlockDuration else { throw InvalidDuration() }
        return TimeInterval(seconds)
    }
}
