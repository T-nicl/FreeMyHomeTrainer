import SwiftData
import SwiftUI

@main
struct FreeMyHomeTrainerApp: App {
    @State private var devices = DeviceManager()
    @State private var appState = AppState()
    @State private var uploads = UploadCenter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(devices)
                .environment(appState)
                .environment(uploads)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .modelContainer(for: [SavedWorkout.self, ActivityRecord.self])
        .windowToolbarStyle(.unified)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case ride, library, history, settings

    var id: Self { self }

    var title: String {
        switch self {
        case .library: "Séances"
        case .ride: "Rouler"
        case .history: "Historique"
        case .settings: "Réglages"
        }
    }

    var icon: String {
        switch self {
        case .library: "list.bullet.rectangle"
        case .ride: "bicycle"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

/// État partagé entre les écrans (section affichée, séance en cours).
@MainActor
@Observable
final class AppState {
    var section: AppSection = .ride
    /// Séance choisie pour la prochaine sortie.
    var selectedWorkoutID: UUID?
    /// Séance en cours (conservée quand on change d'écran).
    var engine: WorkoutEngine?
}

/// Clés des réglages utilisateur stockés dans UserDefaults.
enum Settings {
    static let ftpKey = "ftp"
    static let weightKey = "weightKg"
    static let stravaAutoUploadKey = "stravaAutoUpload"
    static let garminAutoUploadKey = "garminAutoUpload"
    static let stravaClientIDKey = "stravaClientID"
    static let seededKey = "didSeedSampleWorkouts"

    static var ftp: Int {
        let v = UserDefaults.standard.integer(forKey: ftpKey)
        return v > 0 ? v : 200
    }
}

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding($appState.section)) { section in
                Label(section.title, systemImage: section.icon)
                    .badge(section == .ride && appState.engine?.isActive == true ? Text("●") : nil)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            switch appState.section {
            case .library: LibraryView()
            case .ride: RideView()
            case .history: HistoryView()
            case .settings: SettingsView()
            }
        }
        .seedSampleWorkouts()
    }
}

private struct SeedSampleWorkouts: ViewModifier {
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.task {
            guard !UserDefaults.standard.bool(forKey: Settings.seededKey) else { return }
            for w in Workout.samples { context.insert(SavedWorkout(w)) }
            UserDefaults.standard.set(true, forKey: Settings.seededKey)
        }
    }
}

extension View {
    func seedSampleWorkouts() -> some View { modifier(SeedSampleWorkouts()) }
}
