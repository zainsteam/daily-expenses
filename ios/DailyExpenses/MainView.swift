import SwiftUI
import SwiftData

struct EditorTarget: Identifiable {
    let id = UUID()
    let entry: Entry?
}

struct MainView: View {
    @State private var tab = 0
    @State private var today = Day.today()
    @State private var month = Day.month(Day.today())
    @State private var editor: EditorTarget?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView(selection: $tab) {
            OverviewView(month: $month, today: today, tab: $tab, editor: $editor)
                .tabItem { Label("Overview", systemImage: "chart.bar.fill") }
                .tag(0)
            HistoryView(month: $month, today: today, editor: $editor)
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
                .tag(1)
            BudgetsView()
                .tabItem { Label("Budgets", systemImage: "gauge.with.dots.needle.33percent") }
                .tag(2)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(3)
        }
        .sheet(item: $editor) { target in
            EntryEditor(entry: target.entry)
        }
        // Installs from before investments existed get the default investment categories once.
        // Card was removed: older card entries move to bank once.
        .task {
            Defaults.ensureInvestmentCategories(context)
            Defaults.migrateCardToBank(context)
        }
        // The app can sit in the background for days: roll "today" (and the month) forward on return.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let now = Day.today()
            if now != today {
                if month == Day.month(today) { month = Day.month(now) }
                today = now
            }
        }
    }
}

struct MonthToolbar: ViewModifier {
    @Binding var month: String
    let today: String
    @Binding var editor: EditorTarget?

    func body(content: Content) -> some View {
        content
            .navigationTitle(Day.monthLabel(month))
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { month = Day.addMonths(month, -1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous month")
                    Button { month = Day.addMonths(month, 1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next month")
                    if month != Day.month(today) {
                        Button("Now") { month = Day.month(today) }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor = EditorTarget(entry: nil) } label: {
                        Image(systemName: "plus.circle.fill").font(.title2)
                    }
                    .accessibilityLabel("Add an entry")
                }
            }
    }
}

extension View {
    func monthToolbar(month: Binding<String>, today: String, editor: Binding<EditorTarget?>) -> some View {
        modifier(MonthToolbar(month: month, today: today, editor: editor))
    }

    /// The decimal keypad has no return key, so give it a Done button.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

struct EntryRow: View {
    let entry: Entry
    let categoryName: String
    let currency: String
    let dateLabel: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.entryKind == .transfer ? entry.transferLabel : categoryName)
                if !entry.note.isEmpty {
                    Text(entry.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Text([dateLabel, kindNote, entry.entryKind == .transfer ? nil : entry.account.label].compactMap { $0 }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(EntryRow.sign(entry.entryKind) + Money.format(entry.amount, currency))
                .monospacedDigit()
                .foregroundStyle(EntryRow.color(entry.entryKind))
        }
        .contentShape(Rectangle())
    }

    private var kindNote: String? {
        switch entry.entryKind {
        case .investment: return "Invested"
        case .withdrawal: return "Taken out"
        case .transfer: return "Transfer"
        default: return nil
        }
    }

    static func sign(_ kind: EntryKind) -> String {
        kind == .income || kind == .withdrawal ? "+" : ""
    }

    static func color(_ kind: EntryKind) -> Color {
        switch kind {
        case .expense: return .primary
        case .income: return .green
        case .investment, .withdrawal: return .blue
        case .transfer: return .secondary
        }
    }
}

/// A row that opens a searchable currency list. The list closes itself when you pick one,
/// then reports the choice (so a confirmation alert can show on the screen underneath).
struct CurrencyPicker: View {
    let selection: String
    let onSelect: (String) -> Void

    static let all: [(code: String, label: String)] = {
        var codes = Set(Locale.commonISOCurrencyCodes)
        codes.insert("USD")
        return codes.map { code in
            let name = Locale.current.localizedString(forCurrencyCode: code) ?? code
            return (code, name == code ? code : "\(name) (\(code))")
        }.sorted { $0.label.localizedCompare($1.label) == .orderedAscending }
    }()

    static func label(for code: String) -> String {
        all.first { $0.code == code }?.label ?? code
    }

    var body: some View {
        NavigationLink {
            CurrencyList(selection: selection, onSelect: onSelect)
        } label: {
            LabeledContent("Currency", value: Self.label(for: selection))
        }
    }
}

struct CurrencyList: View {
    let selection: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [(code: String, label: String)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return CurrencyPicker.all }
        return CurrencyPicker.all.filter { $0.label.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List(items, id: \.code) { item in
            Button {
                dismiss()
                // Report after the list has closed, so an alert can present on the screen below.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { onSelect(item.code) }
            } label: {
                HStack {
                    Text(item.label).foregroundStyle(Color.primary)
                    Spacer()
                    if item.code == selection {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search currencies")
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SetupView: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.modelContext) private var context
    @State private var currency = Locale.current.currency?.identifier ?? "USD"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Log what you spend in a few taps. Everything is stored on this iPhone: no account, no server.")
                        .foregroundStyle(.secondary)
                }
                Section("Currency") {
                    CurrencyPicker(selection: currency) { currency = $0 }
                }
                Section {
                    Button("Start logging") { start() }
                        .frame(maxWidth: .infinity)
                        .bold()
                }
            }
            .navigationTitle("Daily Expenses")
        }
    }

    private func start() {
        let existing = (try? context.fetchCount(FetchDescriptor<EntryCategory>())) ?? 0
        if existing == 0 {
            Defaults.categories().forEach { context.insert($0) }
        }
        try? context.save()
        prefs.currency = currency
        prefs.createdAt = Prefs.nowMs()
        prefs.setupDone = true
    }
}
