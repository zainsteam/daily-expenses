import SwiftUI
import SwiftData

struct HistoryView: View {
    @Binding var month: String
    let today: String
    @Binding var editor: EditorTarget?

    @Environment(Prefs.self) private var prefs
    @Environment(\.modelContext) private var context
    @Query private var entries: [Entry]
    @Query(sort: \EntryCategory.sortOrder) private var categories: [EntryCategory]

    @State private var kindFilter = "all"
    @State private var methodFilter = "all"
    @State private var categoryFilter = "all"

    private var filtered: Bool { kindFilter != "all" || methodFilter != "all" || categoryFilter != "all" }

    private struct DayGroup: Identifiable {
        let date: String
        var items: [Entry]
        var id: String { date }
        var expense: Int { items.filter { $0.isExpense }.reduce(0) { $0 + $1.amount } }
        var income: Int { items.filter { $0.isIncome }.reduce(0) { $0 + $1.amount } }
        var invested: Int { items.filter { $0.entryKind == .investment }.reduce(0) { $0 + $1.amount } }
    }

    var body: some View {
        let list = entries.filter { e in
            Day.month(e.date) == month
                && (kindFilter == "all" || e.kind == kindFilter || (kindFilter == "investment" && e.entryKind.isInvestment))
                && (methodFilter == "all" || e.account.rawValue == methodFilter
                    || (e.entryKind == .transfer && e.account.other.rawValue == methodFilter))
                && (categoryFilter == "all" || e.categoryId == categoryFilter)
        }.sorted(by: Ledger.byNewest)
        let groups = list.reduce(into: [DayGroup]()) { acc, e in
            if acc.last?.date == e.date { acc[acc.count - 1].items.append(e) } else { acc.append(DayGroup(date: e.date, items: [e])) }
        }
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let spent = list.filter { $0.isExpense }.reduce(0) { $0 + $1.amount }
        let received = list.filter { $0.isIncome }.reduce(0) { $0 + $1.amount }
        let invested = list.filter { $0.entryKind == .investment }.reduce(0) { $0 + $1.amount }

        NavigationStack {
            List {
                if groups.isEmpty {
                    Text(filtered ? "No entries in \(Day.monthLabel(month)) match these filters." : "No entries in \(Day.monthLabel(month)).")
                        .foregroundStyle(.secondary)
                } else {
                    Section {
                        Text(([ "\(list.count) \(list.count == 1 ? "entry" : "entries")" ]
                              + (spent > 0 ? ["\(Money.format(spent, prefs.currency)) spent"] : [])
                              + (received > 0 ? ["\(Money.format(received, prefs.currency)) received"] : [])
                              + (invested > 0 ? ["\(Money.format(invested, prefs.currency)) invested"] : []))
                            .joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.items) { e in
                                Button { editor = EditorTarget(entry: e) } label: {
                                    EntryRow(entry: e, categoryName: names[e.categoryId] ?? "Unknown category",
                                             currency: prefs.currency, dateLabel: nil)
                                }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) { delete(e) } label: { Label("Delete", systemImage: "trash") }
                                }
                            }
                        } header: {
                            HStack {
                                Text(Day.dayLabel(g.date, today: today))
                                Spacer()
                                if g.expense > 0 { Text(Money.format(g.expense, prefs.currency)) }
                                if g.income > 0 { Text("+" + Money.format(g.income, prefs.currency)).foregroundStyle(.green) }
                                if g.invested > 0 { Text(Money.format(g.invested, prefs.currency)).foregroundStyle(.blue) }
                            }
                            .monospacedDigit()
                        }
                    }
                }
            }
            .monthToolbar(month: $month, today: today, editor: $editor)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Type", selection: $kindFilter) {
                            Text("All types").tag("all")
                            Text("Expenses").tag("expense")
                            Text("Income").tag("income")
                            Text("Investments").tag("investment")
                            Text("Transfers").tag("transfer")
                        }
                        .pickerStyle(.menu)
                        Picker("Cash or bank", selection: $methodFilter) {
                            Text("Cash and bank").tag("all")
                            ForEach(PayMethod.selectable) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.menu)
                        Picker("Category", selection: $categoryFilter) {
                            Text("All categories").tag("all")
                            ForEach(categories) { c in
                                Text(c.name + (c.archived ? " (hidden)" : "")).tag(c.id)
                            }
                        }
                        .pickerStyle(.menu)
                        if filtered {
                            Button("Clear filters") {
                                kindFilter = "all"; methodFilter = "all"; categoryFilter = "all"
                            }
                        }
                    } label: {
                        Image(systemName: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")
                }
            }
        }
    }

    private func delete(_ e: Entry) {
        context.delete(e)
        try? context.save()
        prefs.touch()
    }
}
