import SwiftUI
import SwiftData

struct BudgetsView: View {
    @Environment(Prefs.self) private var prefs
    @Environment(\.modelContext) private var context
    @Query(sort: \EntryCategory.sortOrder) private var categories: [EntryCategory]

    @State private var overallText = ""
    @State private var texts: [String: String] = [:]
    @State private var errorText: String?
    @State private var savedNote = false

    private var visible: [EntryCategory] { categories.filter { $0.kind == "expense" && !$0.archived } }

    private func text(_ id: String) -> Binding<String> {
        // Only a real change clears "Saved": closing the keyboard writes the same text back.
        Binding(get: { texts[id] ?? "" }, set: { if texts[id] != $0 { texts[id] = $0; savedNote = false } })
    }

    private var hint: String? {
        let total = visible.reduce(0) { $0 + (Money.read(texts[$1.id] ?? "", currency: prefs.currency).value ?? 0) }
        guard total > 0 else { return nil }
        let overall = Money.read(overallText, currency: prefs.currency).value ?? 0
        if overall > 0 && total > overall {
            return "Category limits add up to \(Money.format(total, prefs.currency)), more than your overall limit of \(Money.format(overall, prefs.currency))."
        }
        return "Category limits add up to \(Money.format(total, prefs.currency))."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Limits repeat every month. Leave a field empty for no limit.").foregroundStyle(.secondary)
                }
                Section("All spending") {
                    limitField("Monthly limit", text: Binding(get: { overallText }, set: { if overallText != $0 { overallText = $0; savedNote = false } }))
                }
                Section {
                    ForEach(visible) { c in limitField(c.name, text: text(c.id)) }
                } header: {
                    Text("By category")
                } footer: {
                    if let hint { Text(hint) }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
                Section {
                    Button(savedNote ? "Saved" : "Save budgets") { save() }
                        .frame(maxWidth: .infinity)
                        .bold()
                }
            }
            .navigationTitle("Budgets")
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .onAppear(perform: load)
        }
    }

    private func limitField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Money.symbol(prefs.currency)).foregroundStyle(.secondary)
            TextField("No limit", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 130)
        }
    }

    private func load() {
        overallText = Money.toInput(prefs.overallBudget)
        var t: [String: String] = [:]
        for c in categories where c.kind == "expense" { t[c.id] = Money.toInput(c.budget) }
        texts = t
        errorText = nil
    }

    private func save() {
        errorText = nil
        func read(_ raw: String, _ label: String) -> Int? {
            let r = Money.read(raw, currency: prefs.currency)
            if let e = r.error { errorText = "\(label): \(e)"; return nil }
            return r.value ?? 0
        }
        guard let overall = read(overallText, "The overall limit") else { return }
        var limits: [String: Int] = [:]
        for c in visible {
            guard let v = read(texts[c.id] ?? "", "The limit for \(c.name)") else { return }
            limits[c.id] = v
        }
        for c in visible { c.budget = limits[c.id] ?? 0 }
        do {
            try context.save()
        } catch {
            context.rollback()
            errorText = "Couldn’t save: \(error.localizedDescription)"
            return
        }
        prefs.overallBudget = overall
        prefs.touch()
        savedNote = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
