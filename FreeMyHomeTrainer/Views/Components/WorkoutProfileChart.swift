import Charts
import SwiftUI

extension PowerZone {
    var color: Color {
        switch self {
        case .z1: Color(red: 0.55, green: 0.56, blue: 0.60)
        case .z2: Color(red: 0.20, green: 0.55, blue: 0.95)
        case .z3: Color(red: 0.25, green: 0.75, blue: 0.40)
        case .z4: Color(red: 0.98, green: 0.78, blue: 0.15)
        case .z5: Color(red: 0.98, green: 0.50, blue: 0.15)
        case .z6: Color(red: 0.92, green: 0.25, blue: 0.25)
        }
    }
}

/// Profil de séance : barres colorées par zone, avec en option la puissance réelle
/// et un curseur de progression (pendant une sortie).
struct WorkoutProfileChart: View {
    let timeline: WorkoutTimeline
    var actual: [Sample] = []
    var progress: TimeInterval?
    var highlightedRange: Range<TimeInterval>?
    var showAxes = true
    /// Trait de la FTP (par défaut : affiché avec les axes).
    var showFTPLine: Bool?

    private struct Bar: Identifiable {
        let id: Int
        let start, end, watts: Double
        let zone: PowerZone
        let isRampStep: Bool
    }

    /// Les rampes sont découpées en marches pour être dessinées avec des rectangles.
    private var bars: [Bar] {
        var out: [Bar] = []
        for s in timeline.segments {
            let steps = s.isRamp ? max(min(Int(s.duration / 10), 40), 2) : 1
            let dt = s.duration / Double(steps)
            for k in 0..<steps {
                let t0 = s.start + Double(k) * dt
                let w = s.watts(at: t0 + dt / 2)
                out.append(Bar(id: out.count, start: t0, end: t0 + dt, watts: w,
                               zone: PowerZone(watts: w, ftp: timeline.ftp), isRampStep: s.isRamp))
            }
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(bars) { bar in
                RectangleMark(xStart: .value("Début", bar.start), xEnd: .value("Fin", bar.end),
                              yStart: .value("0", 0), yEnd: .value("Watts", bar.watts))
                    .foregroundStyle(bar.zone.color.opacity(isHighlighted(bar) ? 1 : dimmedOpacity))
                    .cornerRadius(bar.isRampStep ? 0 : 3)
            }
            if timeline.ftp > 0, showFTPLine ?? showAxes {
                RuleMark(y: .value("FTP", timeline.ftp))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("FTP").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            ForEach(actual, id: \.elapsed) { s in
                // Position dans la séance : les intervalles sautés laissent un trou, pas un décalage.
                LineMark(x: .value("Temps", s.position ?? s.elapsed), y: .value("Puissance", s.power ?? 0))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let progress {
                RuleMark(x: .value("Maintenant", progress))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartXScale(domain: 0...max(timeline.duration, 1))
        .chartYScale(domain: 0...yMax)
        .chartXAxis {
            if showAxes {
                AxisMarks(values: .stride(by: tickStride)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let t = value.as(Double.self) { Text(Format.duration(t)) }
                    }
                }
            }
        }
        .chartYAxis(showAxes ? .automatic : .hidden)
    }

    private var dimmedOpacity: Double { highlightedRange == nil && progress == nil ? 1 : 0.4 }

    private func isHighlighted(_ bar: Bar) -> Bool {
        if let r = highlightedRange { return bar.start >= r.lowerBound && bar.end <= r.upperBound }
        if let p = progress { return bar.start <= p }
        return true
    }

    private var yMax: Double {
        let maxTarget = timeline.segments.map { max($0.startWatts, $0.endWatts) }.max() ?? 100
        let maxActual = Double(actual.compactMap(\.power).max() ?? 0)
        return max(maxTarget * 1.15, maxActual * 1.05, Double(timeline.ftp) * 1.1, 100)
    }

    private var tickStride: Double {
        switch timeline.duration {
        case ..<1200: 300
        case ..<3600: 600
        case ..<7200: 900
        default: 1800
        }
    }
}

/// Résumé chiffré d'une séance planifiée.
struct WorkoutSummaryRow: View {
    let timeline: WorkoutTimeline

    /// S'adapte à la largeur : libellé d'intensité masqué, puis passage sur deux lignes.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { durationAndPower; intensity(showsLabel: true) }
            HStack(spacing: 16) { durationAndPower; intensity(showsLabel: false) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) { durationAndPower }
                intensity(showsLabel: true)
            }
        }
    }

    @ViewBuilder private var durationAndPower: some View {
        StatView(title: "Durée", value: Format.duration(timeline.duration))
        StatView(title: "Puissance moy.", value: "\(Int(timeline.averageWatts.rounded())) W")
    }

    private func intensity(showsLabel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Intensité").font(.caption).foregroundStyle(.secondary)
            IntensityStars(rating: timeline.intensityRating, size: 15, showsLabel: showsLabel)
        }
        .lineLimit(1)
    }
}

struct StatView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
                .minimumScaleFactor(0.7)
        }
        .lineLimit(1)
    }
}

/// Note d'intensité affichée en 5 étoiles (demi-étoiles possibles).
struct IntensityStars: View {
    let rating: Double
    var size: CGFloat = 12
    var showsLabel = false

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: symbol(for: Double(i)))
                        .foregroundStyle(color)
                }
            }
            .font(.system(size: size))
            if showsLabel {
                Text("\(IntensityRating.formatted(rating))/5 · \(IntensityRating.label(rating))")
                    .font(.system(size: size).weight(.semibold).monospacedDigit())
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Intensité \(IntensityRating.formatted(rating)) sur 5")
        .help("Intensité \(IntensityRating.formatted(rating))/5 : \(IntensityRating.label(rating)). "
              + "Combine l'effort par rapport à ta FTP et la durée de la séance.")
    }

    private func symbol(for position: Double) -> String {
        if rating >= position { return "star.fill" }
        if rating >= position - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }

    private var color: Color {
        PowerZone(watts: 0.45 + rating * 0.15, ftp: 1).color
    }
}
