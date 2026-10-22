import AppKit
import SwiftUI

/// Mini-fenêtre flottante pendant la séance : reste au-dessus de tout (y compris d'une vidéo
/// en plein écran dans un autre espace) sans jamais prendre le focus à l'app au premier plan.
@MainActor
final class MiniOverlay {
    static let shared = MiniOverlay()

    private var panel: NSPanel?
    private static let size = CGSize(width: 280, height: 132)
    private static let margin: CGFloat = 16

    var isVisible: Bool { panel != nil }

    func show(engine: WorkoutEngine, devices: DeviceManager) {
        guard panel == nil else { return }
        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = .floating
        // Visible sur tous les bureaux, y compris par-dessus une app en plein écran.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let root = MiniOverlayView(engine: engine, devices: devices, onExpand: { [weak self] in self?.expand() })
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = hosting

        // En haut à droite de l'écran principal, sous la barre des menus.
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - Self.margin,
                                         y: visible.maxY - Self.size.height - Self.margin))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        // La fenêtre principale se range dans le Dock pour libérer l'écran.
        mainWindow?.miniaturize(nil)
    }

    /// Ferme la mini-fenêtre et ramène l'app au premier plan.
    func expand() {
        close()
        if let window = mainWindow {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    }
}

/// Panneau qui accepte les clics sans devenir la fenêtre active.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Contenu de la mini-fenêtre : puissance / cible, intervalle, cardio, cadence, vitesse.
private struct MiniOverlayView: View {
    let engine: WorkoutEngine
    let devices: DeviceManager
    let onExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(engine.power3s.map(String.init) ?? "--")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(powerColor)
                    .contentTransition(.numericText())
                Text("W").font(.headline).foregroundStyle(.secondary)
                if let target = engine.targetWatts {
                    Text("/ \(target)").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(engine.segmentRemaining.map(Format.clock) ?? Format.clock(engine.elapsed))
                        .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(engine.segmentRemaining == nil ? "écoulé" : "intervalle")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            if let segment = engine.currentSegment, let remaining = engine.segmentRemaining {
                ProgressView(value: min(max(1 - remaining / max(segment.duration, 1), 0), 1))
                    .progressViewStyle(.linear)
                    .tint(PowerZone(watts: segment.averageWatts, ftp: engine.ftp).color)
            }

            HStack(spacing: 12) {
                Label(devices.currentHeartRate.map(String.init) ?? "--", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Label(devices.cadence.map { String(Int($0.rounded())) } ?? "--", systemImage: "arrow.trianglehead.2.clockwise")
                Text(String(format: "%.1f km/h", engine.speedKmh))
                Spacer(minLength: 4)
                Button { engine.togglePause() } label: {
                    Image(systemName: engine.state == .paused ? "play.fill" : "pause.fill")
                }
                .help(engine.state == .paused ? "Reprendre" : "Pause")
                Button(action: onExpand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Revenir à l'app")
            }
            .font(.callout.monospacedDigit())
            .buttonStyle(.borderless)
            .labelStyle(.titleAndIcon)
        }
        .lineLimit(1)
        .padding(12)
        .frame(width: 280, height: 132)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }

    /// Vert à ±5 % de la cible, orange en dessous, rouge au-dessus.
    private var powerColor: Color {
        guard let power = engine.power3s, let target = engine.targetWatts, target > 0 else { return .primary }
        let ratio = Double(power) / Double(target)
        return ratio < 0.95 ? .orange : ratio > 1.05 ? .red : .green
    }
}
