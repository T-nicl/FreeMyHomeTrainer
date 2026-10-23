import AppKit
import SwiftUI

/// Mini-fenêtre flottante pendant la séance : reste au-dessus de tout (y compris d'une vidéo
/// en plein écran dans un autre espace) sans jamais prendre le focus à l'app au premier plan.
@MainActor
final class MiniOverlay {
    static let shared = MiniOverlay()

    private var panel: NSPanel?
    /// Fenêtre principale rangée dans le Dock, à restaurer en sortant du mode mini.
    private weak var restoreWindow: NSWindow?
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
        let hosting = FirstClickHostingView(rootView: root)
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
        restoreWindow = mainWindow
        restoreWindow?.miniaturize(nil)
    }

    /// Ferme la mini-fenêtre et ramène l'app au premier plan.
    func expand() {
        close()
        let window = restoreWindow ?? mainWindow
        restoreWindow = nil
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        // Depuis macOS 14, une app en arrière-plan ne peut pas s'activer seule quand une autre
        // (le navigateur) est au premier plan : on passe par le système, comme un clic dans le Dock.
        NSApp.activate()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    private var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.styleMask.contains(.titled) }
    }
}

/// Le premier clic sur la mini-fenêtre (inactive) déclenche directement le bouton.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

            if let segment = engine.currentSegment, let progress = engine.segmentProgress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(PowerZone(watts: segment.averageWatts, ftp: engine.ftp).color)
            }

            HStack(spacing: 12) {
                Label(devices.currentHeartRate.map(String.init) ?? "--", systemImage: "heart.fill")
                    .foregroundStyle(.red)
                Label(devices.cadence.map { String(Int(safe: $0)) } ?? "--", systemImage: "arrow.trianglehead.2.clockwise")
                if let block = engine.blockNumber {
                    Text("Bloc \(block.index)/\(block.count)")
                } else if let gear = engine.gear {
                    // Vitesses virtuelles : changeables sans quitter la vidéo en plein écran.
                    Button { engine.shift(by: -1) } label: { Image(systemName: "minus") }
                        .disabled(gear <= 1)
                        .help("Vitesse plus facile")
                    Text("\(gear)")
                    Button { engine.shift(by: 1) } label: { Image(systemName: "plus") }
                        .disabled(gear >= VirtualGearbox.ratios.count)
                        .help("Vitesse plus dure")
                }
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

    /// Vert dans la cible, orange au-dessus comme en dessous.
    private var powerColor: Color {
        PowerGuidance(power: engine.power3s, target: engine.targetWatts)?.color ?? .primary
    }
}
