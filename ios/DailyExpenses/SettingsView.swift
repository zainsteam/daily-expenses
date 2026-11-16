import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @Query(sort: \EntryCategory.sortOrder) private var categories: [EntryCategory]

    @State private var exportDoc: ExportDocument?
    @State private var exportType: UTType = .json
    @State private var exportName = ""
    @State private var exportIsBackup = false
    @State private var exportStamp = 0
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var pendingRestore: BackupFile?
    @State private var pendingCurrency: String?
    @State private var message: String?

    private func chooseCurrency(_ code: String) {
        guard code != prefs.currency else { return }
        if entries.isEmpty {
            prefs.currency = code
            prefs.touch()
        } else {
            pendingCurrency = code
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Your entries are stored only on this iPhone and are included in its iCloud or computer backup. Save a backup file every week or so as well, in Files or iCloud Drive.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    LabeledContent("Last backup file", value: prefs.lastBackupAt > 0 ? Day.relative(prefs.lastBackupAt) : "never")
                    Button("Back up now") { backup() }
                    Button("Restore a backup") { showImporter = true }
                    Button("Export CSV for spreadsheets") { exportCSV() }
                } header: {
                    Text("Backup")
                }

                Section {
                    CurrencyPicker(selection: prefs.currency, onSelect: chooseCurrency)
                } header: {
                    Text("Currency")
                } footer: {
                    Text("Changing it only changes the symbol. Amounts aren’t converted.")
                }

                StartingBalanceSection()

                CategoryManager(kind: .expense, title: "Expense categories", categories: categories)
                CategoryManager(kind: .income, title: "Income categories", categories: categories)
                CategoryManager(kind: .investment, title: "Investment categories", categories: categories)

                Section("Storage") {
                    LabeledContent("Entries on this iPhone", value: "\(entries.count)")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("Settings")
            .keyboardDoneButton()
            .fileExporter(isPresented: $showExporter, document: exportDoc, contentType: exportType,
                          defaultFilename: exportName) { result in
                switch result {
                case .success:
                    if exportIsBackup { prefs.lastBackupAt = exportStamp }
                    message = exportIsBackup ? "Backup saved." : "CSV exported."
                case .failure(let error):
                    message = "Couldn’t save the file: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .alert("Replace everything on this iPhone?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
                Button("Replace", role: .destructive) {
                    if let file = pendingRestore { restore(file) }
                    pendingRestore = nil
                }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                if let file = pendingRestore {
                    Text("\(file.transactions.count) \(file.transactions.count == 1 ? "entry" : "entries"), saved \(savedWhen(file)). What’s on this iPhone now will be overwritten.")
                }
            }
            .alert("Switch to \(pendingCurrency ?? "")?", isPresented: Binding(get: { pendingCurrency != nil }, set: { if !$0 { pendingCurrency = nil } })) {
                Button("Switch") {
                    if let code = pendingCurrency {
                        prefs.currency = code
                        prefs.touch()
                    }
                    pendingCurrency = nil
                }
                Button("Cancel", role: .cancel) { pendingCurrency = nil }
            } message: {
                Text("Amounts you’ve logged keep their numbers. They aren’t converted.")
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func savedWhen(_ file: BackupFile) -> String {
        guard let s = file.exportedAt else { return "on an unknown date" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        return d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "on an unknown date"
    }

    private func backup() {
        let now = Prefs.nowMs()
        do {
            let data = try Backup.encode(Backup.build(entries: entries, categories: categories, prefs: prefs, now: now))
            exportDoc = ExportDocument(data: data)
            exportType = .json
            exportName = "expenses-backup-\(Day.today())"
            exportIsBackup = true
            exportStamp = now
            showExporter = true
        } catch {
            message = "Couldn’t create the backup: \(error.localizedDescription)"
        }
    }

    private func exportCSV() {
        guard !entries.isEmpty else { message = "Nothing to export yet."; return }
        let text = Backup.csv(entries: entries, categories: categories, currency: prefs.currency)
        exportDoc = ExportDocument(data: Data(text.utf8))
        exportType = .commaSeparatedText
        exportName = "expenses-\(Day.today())"
        exportIsBackup = false
        showExporter = true
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            message = "Couldn’t open the file: \(error.localizedDescription)"
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                message = "Couldn’t read that file."
                return
            }
            switch Backup.check(data) {
            case .failed(let reason): message = reason
            case .ok(let file): pendingRestore = file
            }
        }
    }

    /// Replaces everything in one save: if it fails, nothing changes.
    private func restore(_ file: BackupFile) {
        for e in entries { context.delete(e) }
        for c in categories { context.delete(c) }
        for (i, c) in file.categories.enumerated() {
            context.insert(EntryCategory(id: c.id, name: c.name, kind: c.type, budget: c.budget ?? 0,
                                         archived: c.archived ?? false, sortOrder: i))
        }
        for e in file.transactions {
            context.insert(Entry(id: e.id, kind: e.type, amount: e.amount, categoryId: e.categoryId, method: e.method,
                                 date: e.date, note: e.note ?? "", createdAt: e.createdAt ?? 0, updatedAt: e.updatedAt ?? 0))
        }
        do {
            try context.save()
        } catch {
            context.rollback()
            message = "Restore failed and nothing was changed: \(error.localizedDescription)"
            return
        }
        let s = file.settings
        if let code = s?.currency, code.count == 3, code == code.uppercased() { prefs.currency = code }
        let budget = s?.overallBudget ?? 0
        prefs.overallBudget = budget >= 0 && budget <= Money.maxAmount ? budget : 0
        if let m = s?.lastMethod?["expense"], PayMethod(rawValue: m) != nil { prefs.lastMethodExpense = m }
        if let m = s?.lastMethod?["income"], PayMethod(rawValue: m) != nil { prefs.lastMethodIncome = m }
        if let m = s?.lastMethod?["investment"], PayMethod(rawValue: m) != nil { prefs.lastMethodInvestment = m }
        prefs.lastCategoryExpense = (s?.lastCategory?["expense"] ?? nil) ?? ""
        prefs.lastCategoryIncome = (s?.lastCategory?["income"] ?? nil) ?? ""
        prefs.lastCategoryInvestment = (s?.lastCategory?["investment"] ?? nil) ?? ""
        // Starting balances: restored when the backup has valid ones, otherwise cleared with everything else.
        if let d = s?.startDate, Day.isValid(d) {
            prefs.startCash = min(max(s?.startCash ?? 0, 0), Money.maxAmount)
            prefs.startBank = min(max(s?.startBank ?? 0, 0), Money.maxAmount)
            prefs.startDate = d
        } else {
            prefs.startCash = 0
            prefs.startBank = 0
            prefs.startDate = ""
        }
        // Backups from before investments existed: add the default investment categories.
        Defaults.ensureInvestmentCategories(context)
        // The restored data matches a file the user already has, so it counts as backed up.
        prefs.lastBackupAt = Prefs.nowMs()
        prefs.lastChangeAt = 0
        message = "Restored \(file.transactions.count) \(file.transactions.count == 1 ? "entry" : "entries")."
    }
}

/// What you had in cash and in the bank at the start of a day. The Overview adds every entry
/// from that day on to show the balance now.
struct StartingBalanceSection: View {
    @Environment(Prefs.self) private var prefs
    @State private var cashText = ""
    @State private var bankText = ""
    @State private var date = Date()
    @State private var message: String?
    @State private var saved = false

    var body: some View {
        Section {
            amountRow("Cash in hand", text: $cashText)
            amountRow("Bank", text: $bankText)
            DatePicker("As of the start of", selection: $date, displayedComponents: .date)
                .onChange(of: date) { _, _ in saved = false }
            Button(saved ? "Saved" : "Save starting balances") { save() }
            if prefs.hasStartingBalance {
                Button("Remove starting balances", role: .destructive) { clear() }
            }
        } header: {
            Text("Starting balances")
        } footer: {
            if let message { Text(message).foregroundStyle(.red) }
            else {
                Text("Enter what you had before the entries you log from this date. The Overview then shows your cash and bank balance now. Entries before this date don’t change it.")
            }
        }
        .onAppear(perform: load)
    }

    private func amountRow(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Money.symbol(prefs.currency)).foregroundStyle(.secondary)
            TextField("0", text: Binding(get: { text.wrappedValue }, set: {
                if text.wrappedValue != $0 { text.wrappedValue = $0; saved = false }
            }))
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 130)
        }
    }

    private func load() {
        cashText = Money.toInput(prefs.startCash)
        bankText = Money.toInput(prefs.startBank)
        date = prefs.hasStartingBalance ? Day.date(prefs.startDate) : Date()
        message = nil
    }

    private func save() {
        message = nil
        let cash = Money.read(cashText, currency: prefs.currency)
        let bank = Money.read(bankText, currency: prefs.currency)
        if let e = cash.error { message = "Cash: \(e)"; return }
        if let e = bank.error { message = "Bank: \(e)"; return }
        prefs.startCash = cash.value ?? 0
        prefs.startBank = bank.value ?? 0
        prefs.startDate = Day.iso(date)
        prefs.touch()
        saved = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func clear() {
        prefs.startCash = 0
        prefs.startBank = 0
        prefs.startDate = ""
        prefs.touch()
        load()
        saved = false
    }
}

struct CategoryManager: View {
    let kind: EntryKind
    let title: String
    let categories: [EntryCategory]

    @Environment(\.modelContext) private var context
    @Environment(Prefs.self) private var prefs
    @State private var newName = ""
    @State private var message: String?

    private var mine: [EntryCategory] { categories.filter { $0.kind == kind.rawValue } }

    var body: some View {
        Section {
            ForEach(mine) { c in
                HStack {
                    CategoryNameField(category: c, siblings: mine)
                        .foregroundStyle(c.archived ? .secondary : .primary)
                    Button(c.archived ? "Show" : "Hide") { toggle(c) }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("New category", text: $newName)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(.borderless)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(title)
        } footer: {
            if let message { Text(message).foregroundStyle(.red) }
            else if kind == .investment {
                Text("Investments, like plot instalments and BCs, aren’t counted as spending. Hidden categories stay on past entries but aren’t offered for new ones.")
            }
        }
    }

    private func toggle(_ c: EntryCategory) {
        message = nil
        if !c.archived && mine.filter({ !$0.archived }).count <= 1 {
            message = "Keep at least one \(kind.rawValue) category visible."
            return
        }
        c.archived.toggle()
        try? context.save()
        prefs.touch()
    }

    private func add() {
        message = nil
        let name = String(newName.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(Limits.nameMax))
        guard !name.isEmpty else { return }
        if mine.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            message = "\(name) already exists."
            return
        }
        let order = (categories.map(\.sortOrder).max() ?? 0) + 1
        context.insert(EntryCategory(id: UUID().uuidString, name: name, kind: kind.rawValue, sortOrder: order))
        try? context.save()
        prefs.touch()
        newName = ""
    }
}

/// Renames on Return or when focus leaves; empty or duplicate names snap back.
struct CategoryNameField: View {
    let category: EntryCategory
    let siblings: [EntryCategory]

    @Environment(\.modelContext) private var context
    @Environment(Prefs.self) private var prefs
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .onAppear { text = category.name }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let name = String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(Limits.nameMax))
        let duplicate = siblings.contains { $0.id != category.id && $0.name.lowercased() == name.lowercased() }
        guard !name.isEmpty, !duplicate, name != category.name else {
            text = category.name
            return
        }
        category.name = name
        try? context.save()
        prefs.touch()
        text = name
    }
}
