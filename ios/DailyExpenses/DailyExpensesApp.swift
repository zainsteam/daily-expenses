import SwiftUI
import SwiftData

@main
struct DailyExpensesApp: App {
    @State private var prefs = Prefs()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(prefs)
        }
        // Stored in the app's own container on this iPhone. Included in the phone's iCloud or computer backup.
        .modelContainer(for: [Entry.self, EntryCategory.self])
    }
}

struct RootView: View {
    @Environment(Prefs.self) private var prefs

    var body: some View {
        if prefs.setupDone {
            MainView()
        } else {
            SetupView()
        }
    }
}
