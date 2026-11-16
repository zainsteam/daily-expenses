import SwiftUI
import SwiftData
import Charts

struct OverviewView: View {
    @Binding var month: String
    let today: String
    @Binding var tab: Int
    @Binding var editor: EditorTarget?

    @Environment(Prefs.self) private var prefs
    @Query private var entries: [Entry]
    @Query(sort: \EntryCategory.sortOrder) private var categories: [EntryCategory]
    @State private var backupSnoozed = false

    private func money(_ minor: Int) -> String { Money.format(minor, prefs.currency) }

    var body: some View {
        let sum = MonthSummary(entries: entries, month: month, categories: categories,
                               overallBudget: prefs.overallBudget, today: today)
        let thisMonth = Day.month(today)
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        NavigationStack {
            List {
                if prefs.backupDue(entryCount: entries.count) && !backupSnoozed {
                    Section {
                        Text(prefs.lastBackupAt > 0
                             ? "Last backup file: \(Day.relative(prefs.lastBackupAt))."
                             : "You haven’t saved a backup file yet.")
                        HStack {
                            Button("Back up now") { tab = 3 }.buttonStyle(.borderedProminent)
                            Button("Later") { backupSnoozed = true }.buttonStyle(.bordered)
                        }
                    }
                }

                Section {
                    hero(sum, thisMonth: thisMonth)
                }

                if month == thisMonth {
                    balanceSection
                }

                if sum.count == 0 {
                    Section {
                        Text(month < thisMonth
                             ? "Nothing was logged in \(Day.monthLabel(month))."
                             : "Nothing logged in \(Day.monthLabel(month)) yet. Tap + to add your first expense.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        let recent = entries.filter { Day.month($0.date) == month }.sorted(by: Ledger.byNewest).prefix(4)
                        ForEach(Array(recent)) { e in
                            Button { editor = EditorTarget(entry: e) } label: {
                                EntryRow(entry: e, categoryName: names[e.categoryId] ?? "Unknown category",
                                         currency: prefs.currency, dateLabel: Day.dayLabel(e.date, today: today))
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text("Latest entries")
                            Spacer()
                            Button("See all") { tab = 1 }.font(.footnote).textCase(nil)
                        }
                    }

                    if !sum.budgetRows.isEmpty {
                        Section("Budgets") {
                            ForEach(sum.budgetRows) { BudgetRowView(line: $0, currency: prefs.currency) }
                        }
                    } else if sum.overall == nil {
                        Section {
                            Text("Set monthly limits to see how your spending is pacing.")
                            Button("Set budgets") { tab = 2 }
                        }
                    }

                    if !sum.categoryRows.isEmpty {
                        Section("Where it went") {
                            ForEach(sum.categoryRows) { r in
                                ShareRow(name: r.name, share: r.share, amount: money(r.amount), tint: .accentColor)
                            }
                        }
                    }

                    if sum.hasInvestments {
                        Section {
                            ForEach(sum.investmentRows) { r in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(r.name)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        if r.putIn > 0 { Text(money(r.putIn)).foregroundStyle(.blue) }
                                        if r.takenOut > 0 {
                                            Text("+\(money(r.takenOut)) taken out").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .monospacedDigit()
                                }
                            }
                        } header: {
                            Text("Invested")
                        } footer: {
                            Text("Not counted as spending or in your budgets.")
                        }
                    }

                    if sum.expense > 0 {
                        Section("Paid with") {
                            ForEach(PayMethod.selectable) { m in
                                let v = sum.byMethod[m] ?? 0
                                ShareRow(name: m.label, share: Double(v) / Double(sum.expense), amount: money(v),
                                         tint: m == .cash ? .orange : .purple)
                            }
                        }
                    }

                    // Everything that moved in and out of cash and the bank this month, transfers included.
                    Section {
                        ForEach(sum.accounts) { a in
                            HStack(alignment: .firstTextBaseline) {
                                Text(a.account.label)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text((a.net > 0 ? "+" : "") + money(a.net))
                                        .foregroundStyle(a.net < 0 ? Color.red : Color.primary)
                                    Text("in \(money(a.inflow)) · out \(money(a.outflow))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .monospacedDigit()
                            }
                        }
                    } header: {
                        Text("Cash & bank this month")
                    } footer: {
                        Text(sum.transferred > 0
                             ? "Includes \(money(sum.transferred)) moved between cash and bank."
                             : "Use Transfer to record cash taken out of or put into the bank.")
                    }
                }
            }
            .monthToolbar(month: $month, today: today, editor: $editor)
        }
    }

    /// Cash and bank now, from the starting balances in Settings.
    @ViewBuilder
    private var balanceSection: some View {
        if prefs.hasStartingBalance {
            let b = Ledger.balances(entries: entries, startCash: prefs.startCash, startBank: prefs.startBank,
                                    from: prefs.startDate, through: today)
            Section {
                HStack {
                    balanceCell("Cash in hand", b.cash, alignment: .leading)
                    Spacer()
                    balanceCell("Bank", b.bank, alignment: .center)
                    Spacer()
                    balanceCell("Total", b.cash + b.bank, alignment: .trailing)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            } header: {
                Text("Balance now")
            } footer: {
                Text("Starting balances (\(Day.dayLabel(prefs.startDate, today: today).lowercased())) plus everything logged since. Change them in Settings.")
            }
        } else {
            Section {
                Button("Add your cash and bank balance") { tab = 3 }
            } footer: {
                Text("Set starting balances in Settings to see how much cash and bank money you have now.")
            }
        }
    }

    private func balanceCell(_ label: String, _ minor: Int, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(money(minor)).monospacedDigit().foregroundStyle(minor < 0 ? Color.red : Color.primary)
        }
    }

    @ViewBuilder
    private func hero(_ sum: MonthSummary, thisMonth: String) -> some View {
        let isCurrent = month == thisMonth
        let isPast = month < thisMonth
        VStack(alignment: .leading, spacing: 10) {
            Text(isCurrent ? "Spent this month" : "Spent in \(Day.monthLabel(month))")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(money(sum.expense))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)

            DailyChart(daily: sum.daily, allowance: sum.dailyAllowance,
                       todayDay: isCurrent ? (Int(today.suffix(2)) ?? 0) : 0,
                       futureMonth: month > thisMonth)

            VStack(alignment: .leading, spacing: 4) {
                if isCurrent {
                    Text("Spent today: \(money(sum.todayExpense))")
                }
                if let o = sum.overall {
                    if o.left < 0 {
                        Text("\(money(-o.left)) over your \(money(o.limit)) budget.").foregroundStyle(.red)
                    } else if isPast {
                        Text("Finished \(money(o.left)) under your \(money(o.limit)) budget.")
                    } else if isCurrent {
                        Text("\(money(o.left)) left of \(money(o.limit)). About \(money(sum.pacePerDay)) a day for the remaining \(sum.paceDaysLeft) \(sum.paceDaysLeft == 1 ? "day" : "days").")
                    } else {
                        Text("\(money(o.left)) left of \(money(o.limit)).")
                    }
                    Text("Dashed line: daily budget \(money(sum.dailyAllowance))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if sum.elapsedDays > 0 && sum.expense > 0 {
                    Text("Average \(money(Int((Double(sum.expense) / Double(sum.elapsedDays)).rounded()))) a day.")
                }
            }
            .font(.subheadline)

            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    Text("Income").font(.caption).foregroundStyle(.secondary)
                    Text(money(sum.income)).monospacedDigit().foregroundStyle(.green)
                }
                if sum.hasInvestments {
                    Spacer()
                    VStack {
                        Text("Invested").font(.caption).foregroundStyle(.secondary)
                        Text(money(sum.netInvested)).monospacedDigit().foregroundStyle(.blue)
                    }
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Left over").font(.caption).foregroundStyle(.secondary)
                    Text((sum.leftOver > 0 ? "+" : "") + money(sum.leftOver)).monospacedDigit()
                        .foregroundStyle(sum.leftOver < 0 ? Color.red : Color.primary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 6)
    }
}

/// One bar per day of the month; the dashed line is the average daily budget.
struct DailyChart: View {
    let daily: [Int]
    let allowance: Int
    let todayDay: Int
    let futureMonth: Bool

    private func color(day: Int, value: Int) -> Color {
        if futureMonth || (todayDay > 0 && day > todayDay) { return Color.secondary.opacity(0.2) }
        if allowance > 0 && value > allowance { return .orange }
        if day == todayDay { return .accentColor }
        return Color.accentColor.opacity(0.55)
    }

    var body: some View {
        VStack(spacing: 2) {
            Chart {
                ForEach(Array(daily.enumerated()), id: \.offset) { item in
                    BarMark(x: .value("Day", String(item.offset + 1)),
                            y: .value("Spent", Double(item.element) / 100))
                        .foregroundStyle(color(day: item.offset + 1, value: item.element))
                }
                if allowance > 0 {
                    RuleMark(y: .value("Daily budget", Double(allowance) / 100))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(Color.secondary)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 80)
            HStack {
                Text("1")
                Spacer()
                if todayDay > 0 { Text("Today \(todayDay)") }
                Spacer()
                Text("\(daily.count)")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily spending chart")
    }
}

struct ShareRow: View {
    let name: String
    let share: Double
    let amount: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name)
                Text("\(Int((share * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(amount).monospacedDigit()
            }
            ProgressView(value: min(max(share, 0), 1)).tint(tint)
        }
    }
}

struct BudgetRowView: View {
    let line: BudgetLine
    let currency: String

    private var tint: Color {
        switch line.status {
        case .ok: return .accentColor
        case .warn: return .orange
        case .over: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(line.name)
                Spacer()
                Text(Money.format(line.spent, currency)).monospacedDigit()
                Text("of \(Money.format(line.limit, currency))").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: min(line.ratio, 1)).tint(tint)
            Text(line.left >= 0 ? "\(Money.format(line.left, currency)) left" : "\(Money.format(-line.left, currency)) over")
                .font(.caption)
                .foregroundStyle(line.status == .ok ? Color.secondary : tint)
        }
    }
}
