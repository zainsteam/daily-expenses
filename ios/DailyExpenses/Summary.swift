import Foundation

enum BudgetStatus { case ok, warn, over }

struct BudgetLine: Identifiable {
    let id: String
    let name: String
    let limit: Int
    let spent: Int
    var left: Int { limit - spent }
    var ratio: Double { limit > 0 ? Double(spent) / Double(limit) : 0 }
    var status: BudgetStatus { ratio > 1 ? .over : ratio >= 0.8 ? .warn : .ok }
}

struct CategoryShare: Identifiable {
    let id: String
    let name: String
    let amount: Int
    let share: Double
}

struct InvestmentLine: Identifiable {
    let id: String
    let name: String
    var putIn: Int
    var takenOut: Int
}

/// Money that came into and went out of one account (cash or bank) during the month.
struct AccountFlow: Identifiable {
    let account: PayMethod
    var inflow = 0
    var outflow = 0
    var id: String { account.rawValue }
    var net: Int { inflow - outflow }
}

/// Everything the overview needs for one month.
struct MonthSummary {
    let month: String
    let days: Int
    var daily: [Int]
    var count = 0
    var income = 0
    var expense = 0
    var todayExpense = 0
    var invested = 0
    var withdrawn = 0
    var investmentRows: [InvestmentLine] = []
    var transferred = 0
    var accounts: [AccountFlow] = PayMethod.selectable.map { AccountFlow(account: $0) }
    let elapsedDays: Int
    var categoryRows: [CategoryShare] = []
    var budgetRows: [BudgetLine] = []
    var byMethod: [PayMethod: Int] = [:]
    var overall: BudgetLine?
    var paceDaysLeft = 0
    var pacePerDay = 0
    let dailyAllowance: Int

    /// Investments are not spending, but the money has left your pocket; withdrawals bring it back.
    var netInvested: Int { invested - withdrawn }
    var leftOver: Int { income - expense - netInvested }
    var hasInvestments: Bool { invested > 0 || withdrawn > 0 }

    init(entries: [Entry], month: String, categories: [EntryCategory], overallBudget: Int, today: String) {
        self.month = month
        days = Day.daysIn(month)
        daily = Array(repeating: 0, count: days)
        var byCat: [String: Int] = [:]
        var byInvestment: [String: (putIn: Int, takenOut: Int)] = [:]

        var flows: [PayMethod: AccountFlow] = [:]

        for e in entries where Day.month(e.date) == month {
            count += 1
            let account = e.account
            for (m, delta) in Ledger.deltas(e) {
                if delta > 0 { flows[m, default: AccountFlow(account: m)].inflow += delta }
                else { flows[m, default: AccountFlow(account: m)].outflow -= delta }
            }
            switch e.entryKind {
            case .income:
                income += e.amount
                continue
            case .investment:
                invested += e.amount
                byInvestment[e.categoryId, default: (0, 0)].putIn += e.amount
                continue
            case .withdrawal:
                withdrawn += e.amount
                byInvestment[e.categoryId, default: (0, 0)].takenOut += e.amount
                continue
            case .transfer:
                // Your own money changing place: not spending, income or investment.
                transferred += e.amount
                continue
            case .expense:
                break
            }
            expense += e.amount
            byCat[e.categoryId, default: 0] += e.amount
            byMethod[account, default: 0] += e.amount
            if let day = Int(e.date.suffix(2)), day >= 1, day <= days { daily[day - 1] += e.amount }
            if e.date == today { todayExpense += e.amount }
        }

        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let total = expense
        categoryRows = byCat.map { id, amount in
            CategoryShare(id: id, name: names[id] ?? "Unknown category", amount: amount,
                          share: total > 0 ? Double(amount) / Double(total) : 0)
        }.sorted { $0.amount > $1.amount }

        accounts = PayMethod.selectable.map { flows[$0] ?? AccountFlow(account: $0) }

        investmentRows = byInvestment.map { id, v in
            InvestmentLine(id: id, name: names[id] ?? "Unknown category", putIn: v.putIn, takenOut: v.takenOut)
        }.sorted { ($0.putIn + $0.takenOut) > ($1.putIn + $1.takenOut) }

        budgetRows = categories
            .filter { $0.kind == "expense" && !$0.archived && $0.budget > 0 }
            .map { BudgetLine(id: $0.id, name: $0.name, limit: $0.budget, spent: byCat[$0.id] ?? 0) }
            .sorted { $0.ratio > $1.ratio }

        let thisMonth = Day.month(today)
        elapsedDays = month < thisMonth ? days : month == thisMonth ? (Int(today.suffix(2)) ?? 0) : 0
        dailyAllowance = overallBudget > 0 ? Int((Double(overallBudget) / Double(days)).rounded()) : 0
        if overallBudget > 0 {
            let line = BudgetLine(id: "overall", name: "All spending", limit: overallBudget, spent: expense)
            overall = line
            if month == thisMonth {
                paceDaysLeft = days - elapsedDays + 1 // today still counts as a day you can spend
                pacePerDay = line.left > 0 ? line.left / max(paceDaysLeft, 1) : 0
            }
        }
    }
}

enum Ledger {
    static func byNewest(_ a: Entry, _ b: Entry) -> Bool {
        if a.date != b.date { return a.date > b.date }
        return a.createdAt > b.createdAt
    }

    /// How an entry changes cash and bank: money in is positive, money out negative.
    static func deltas(_ e: Entry) -> [(PayMethod, Int)] {
        let account = e.account
        switch e.entryKind {
        case .income, .withdrawal: return [(account, e.amount)]
        case .expense, .investment: return [(account, -e.amount)]
        case .transfer: return [(account, -e.amount), (account.other, e.amount)]
        }
    }

    /// Cash and bank now: the starting balances plus every entry from the starting date up to today.
    /// Entries before the starting date are already part of the starting balance.
    static func balances(entries: [Entry], startCash: Int, startBank: Int, from start: String, through today: String) -> (cash: Int, bank: Int) {
        var cash = startCash
        var bank = startBank
        for e in entries where e.date >= start && e.date <= today {
            for (account, delta) in deltas(e) {
                if account == .cash { cash += delta } else { bank += delta }
            }
        }
        return (cash, bank)
    }
}
