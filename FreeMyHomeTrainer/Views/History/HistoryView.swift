import AppKit
import Charts
import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ActivityRecord.startDate, order: .reverse) private var activities: [ActivityRecord]
    @State private var selection: ActivityRecord.ID?

    var body: some View {
        HStack(spacing: 0) {
            List(activities, selection: $selection) { activity in
                VStack(alignment: .leading, spacing: 3) {
                    Text(activity.name).font(.headline)
                    Text(activity.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("\(Format.clock(activity.timerTime)) · \(activity.avgPower) W")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        IntensityStars(rating: activity.intensityRating, size: 10)
                    }
                }
                .lineLimit(1)
                .padding(.vertical, 3)
                .tag(activity.id)
                .contextMenu {
                    Button("Supprimer", role: .destructive) { delete(activity) }
                }
            }
            .frame(width: 250)
            .overlay {
                if activities.isEmpty {
                    ContentUnavailableView("Aucune sortie", systemImage: "bicycle",
                                           description: Text("Tes séances apparaîtront ici."))
                }
            }

            Divider()

            Group {
                if let activity = activities.first(where: { $0.id == selection }) {
                    ActivityDetailView(activity: activity, onDelete: { delete(activity) })
                        .id(activity.id)
                } else {
                    ContentUnavailableView("Aucune sortie sélectionnée", systemImage: "chart.xyaxis.line")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Historique")
        .onAppear { if selection == nil { selection = activities.first?.id } }
    }

    private func delete(_ activity: ActivityRecord) {
        if let url = activity.fitFileURL { try? FileManager.default.removeItem(at: url) }
        if selection == activity.id { selection = nil }
        context.delete(activity)
        try? context.save()
    }
}

private struct ActivityDetailView: View {
    let activity: ActivityRecord
    let onDelete: () -> Void
    @State private var samples: [Sample] = []
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text(activity.name).font(.title.weight(.bold))
                        Text(activity.startDate.formatted(date: .complete, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Supprimer", systemImage: "trash") }
                }

                ActivityStatsGrid(activity: activity)
                UploadStatusView(activity: activity)

                chart("Puissance (W)", color: .blue, value: { $0.power }, target: true)
                if samples.contains(where: { $0.heartRate != nil }) {
                    chart("Fréquence cardiaque (bpm)", color: .red, value: { $0.heartRate })
                }
                chart("Cadence (rpm)", color: .purple, value: { $0.cadence })

                lapsTable
            }
            .padding(24)
        }
        .task { samples = activity.samples }
        .confirmationDialog("Supprimer cette sortie ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive, action: onDelete)
        } message: {
            Text("Elle restera sur Garmin Connect et Strava si elle y a été envoyée.")
        }
    }

    private func chart(_ title: String, color: Color, value: @escaping (Sample) -> Int?, target: Bool = false) -> some View {
        let points = downsampled
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Chart {
                if target {
                    ForEach(points, id: \.elapsed) { s in
                        if let t = s.target {
                            AreaMark(x: .value("Temps", s.elapsed), y: .value("Cible", t))
                                .foregroundStyle(.gray.opacity(0.25))
                        }
                    }
                }
                ForEach(points, id: \.elapsed) { s in
                    if let v = value(s) {
                        LineMark(x: .value("Temps", s.elapsed), y: .value(title, v))
                            .foregroundStyle(color)
                    }
                }
            }
            .chartXAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let t = v.as(Double.self) { Text(Format.duration(t)) } }
                }
            }
            .frame(height: 160)
        }
    }

    private var downsampled: [Sample] {
        let stride = max(samples.count / 1200, 1)
        return samples.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }

    @ViewBuilder private var lapsTable: some View {
        let laps = activity.laps
        if laps.count > 1, !samples.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Intervalles").font(.headline)
                ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow {
                        Text("#"); Text("Durée"); Text("Cible"); Text("Puiss. moy"); Text("Max"); Text("FC moy"); Text("Cadence")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    ForEach(Array(laps.enumerated()), id: \.offset) { i, lap in
                        let slice = samples[lap.sampleRange.clamped(to: samples.indices)]
                        let m = ActivityMetrics(samples: slice, ftp: activity.ftp)
                        let targets = slice.compactMap(\.target)
                        GridRow {
                            Text("\(i + 1)")
                            Text(Format.clock(lap.timerTime))
                            Text(targets.isEmpty ? "–" : "\(targets.reduce(0, +) / targets.count) W")
                            Text("\(m.avgPower) W")
                            Text("\(m.maxPower) W")
                            Text(m.avgHeartRate.map { "\($0)" } ?? "–")
                            Text(m.avgCadence.map { "\($0)" } ?? "–")
                        }
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                }
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

/// Chiffres clés d'une activité.
struct ActivityStatsGrid: View {
    let activity: ActivityRecord

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], spacing: 14) {
            StatView(title: "Durée", value: Format.clock(activity.timerTime))
            StatView(title: "Distance", value: String(format: "%.1f km", activity.distance / 1000))
            StatView(title: "Puissance moy.", value: "\(activity.avgPower) W")
            StatView(title: "Puissance max", value: "\(activity.maxPower) W")
            VStack(alignment: .leading, spacing: 2) {
                Text("Intensité").font(.caption).foregroundStyle(.secondary)
                IntensityStars(rating: activity.intensityRating, size: 15)
                    .frame(height: 24)
            }
            .lineLimit(1)
            StatView(title: "FC moy. / max", value: activity.avgHeartRate.map {
                "\($0) / \(activity.maxHeartRate ?? $0) bpm"
            } ?? "–")
            StatView(title: "Cadence moy.", value: activity.avgCadence.map { "\($0) rpm" } ?? "–")
            StatView(title: "Travail", value: String(format: "%.0f kJ", activity.kilojoules))
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// État de l'envoi Garmin (→ Strava), avec relance et export manuel du .FIT.
struct UploadStatusView: View {
    let activity: ActivityRecord
    @Environment(UploadCenter.self) private var uploads
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    services
                    Spacer(minLength: 8)
                    exportButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) { services }
                    exportButton
                }
            }
            .lineLimit(1)
            if let error = activity.lastUploadError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private var services: some View {
        service("Garmin", status: activity.garminStatus, connected: uploads.garminConnected) {
            Task { await uploads.uploadToGarmin(activity, context: context) }
        }
    }

    private var exportButton: some View {
        Button { exportFIT() } label: { Label("Exporter le .FIT…", systemImage: "square.and.arrow.up") }
            .disabled(activity.fitFileURL == nil)
    }

    @ViewBuilder
    private func service(_ name: String, status: UploadStatus, connected: Bool, upload: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            switch status {
            case .done:
                Label("\(name) ✓", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .pending, .uploading:
                ProgressView().controlSize(.small)
                Text("\(name)…")
            case .failed:
                Label(name, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button("Renvoyer", action: upload).disabled(!connected)
            case .none:
                Button("Envoyer sur \(name)", action: upload).disabled(!connected)
            }
        }
        .help(connected ? "" : "Connecte ton compte \(name) dans les Réglages.")
    }

    private func exportFIT() {
        guard let source = activity.fitFileURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ActivitySaver.exportFileName(for: activity)
        panel.allowedContentTypes = [.init(filenameExtension: "fit") ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: source, to: destination)
    }
}
