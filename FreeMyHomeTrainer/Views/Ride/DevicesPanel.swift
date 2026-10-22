import SwiftUI

/// Connexion du home trainer et de la ceinture cardio.
struct DevicesPanel: View {
    @Environment(DeviceManager.self) private var devices

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Capteurs").font(.title2.weight(.semibold)).lineLimit(1)
                Spacer()
                if devices.isScanning {
                    ProgressView().controlSize(.small)
                    Button("Arrêter") { devices.stopScan() }
                } else {
                    Button { devices.startScan() } label: {
                        Label("Rechercher", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .fixedSize()
                    .disabled(!devices.bluetoothReady)
                }
            }

            if !devices.bluetoothReady {
                Label("Bluetooth indisponible : active-le et autorise l'app dans Réglages Système › Confidentialité.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            DeviceStatusRow(icon: "bicycle", title: "Home trainer",
                            name: devices.trainerName, state: devices.trainerState,
                            detail: trainerDetail,
                            onForget: devices.isSimulating ? nil : { devices.disconnect(.trainer, forget: true) })
            DeviceStatusRow(icon: "heart.fill", title: "Cardio",
                            name: devices.heartRateName, state: devices.heartRateState,
                            detail: devices.heartRate.map { "\($0) bpm" },
                            onForget: { devices.disconnect(.heartRate, forget: true) })

            if !devices.discovered.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Appareils trouvés").font(.headline)
                    ForEach(devices.discovered) { device in
                        HStack {
                            Image(systemName: device.kind == .trainer ? "bicycle" : "heart")
                                .frame(width: 20)
                            Text(device.name).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Button("Connecter") { devices.connect(device) }
                                .fixedSize()
                        }
                        .lineLimit(1)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            Toggle("Trainer simulé (sans vélo)", isOn: Binding(
                get: { devices.isSimulating },
                set: { $0 ? devices.startSimulation() : devices.stopSimulation() }))
                .toggleStyle(.switch)
                .font(.callout)
        }
    }

    private var trainerDetail: String? {
        guard devices.trainerState == .connected else { return nil }
        var parts: [String] = []
        if let p = devices.power { parts.append("\(p) W") }
        if let c = devices.cadence { parts.append("\(Int(c)) rpm") }
        if !devices.hasControl { parts.append("ERG non disponible") }
        return parts.isEmpty ? "En attente de données…" : parts.joined(separator: " · ")
    }
}

private struct DeviceStatusRow: View {
    let icon: String
    let title: String
    let name: String?
    let state: LinkState
    let detail: String?
    let onForget: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(state == .connected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? title).font(.headline)
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(name == nil ? "Aucun appareil" : state.label)
                    if let detail { Text("· \(detail)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if name != nil, let onForget {
                Button("Oublier", action: onForget).controlSize(.small)
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}
