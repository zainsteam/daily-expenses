import Foundation
import SwiftData

/// `investment` is money put into a plot, BC, gold and so on; `withdrawal` is money taken back out
/// (a BC payout, selling gold). Neither counts as spending or income; both use investment categories.
enum EntryKind: String, CaseIterable, Identifiable {
    case expense, income, investment, withdrawal, transfer
    var id: String { rawValue }

    var label: String {
        switch self {
        case .expense: return "Expense"
        case .income: return "Income"
        case .investment: return "Investment"
        case .withdrawal: return "Withdrawal"
        case .transfer: return "Transfer"
        }
    }

    /// The kind of category this entry uses ("" for a transfer, which has none).
    var categoryKind: String {
        switch self {
        case .withdrawal: return EntryKind.investment.rawValue
        case .transfer: return ""
        default: return rawValue
        }
    }
    var isInvestment: Bool { self == .investment || self == .withdrawal }
    var needsCategory: Bool { self != .transfer }

    /// The choices on the add sheet; withdrawal is picked inside Investment.
    static let pickable: [EntryKind] = [.expense, .income, .investment, .transfer]
}

/// Where the money is: cash in hand or the bank account. `card` exists only so entries and backups
/// from before it was removed still load; it is treated as bank, since card payments come from the bank.
enum PayMethod: String, CaseIterable, Identifiable {
    case cash, card, bank
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    static let selectable: [PayMethod] = [.cash, .bank]
    var account: PayMethod { self == .card ? .bank : self }
    /// For a transfer, `method` is the account the money left; it lands in the other one.
    var other: PayMethod { account == .cash ? .bank : .cash }
}

/// One expense or income. Amounts are integer hundredths ("minor units") so totals never drift.
/// `date` is a local calendar date, "yyyy-MM-dd", so it never shifts with time zones.
@Model
final class Entry {
    var id: String
    var kind: String
    var amount: Int
    var categoryId: String
    var method: String
    var date: String
    var note: String
    var createdAt: Int
    var updatedAt: Int

    init(id: String = UUID().uuidString, kind: String, amount: Int, categoryId: String, method: String,
         date: String, note: String, createdAt: Int, updatedAt: Int) {
        self.id = id
        self.kind = kind
        self.amount = amount
        self.categoryId = categoryId
        self.method = method
        self.date = date
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var entryKind: EntryKind { EntryKind(rawValue: kind) ?? .expense }
    var account: PayMethod { (PayMethod(rawValue: method) ?? .cash).account }

    /// "Bank → Cash" for a transfer.
    var transferLabel: String { "\(account.label) → \(account.other.label)" }
    var isIncome: Bool { entryKind == .income }
    var isExpense: Bool { entryKind == .expense }
}

@Model
final class EntryCategory {
    var id: String
    var name: String
    var kind: String
    var budget: Int
    var archived: Bool
    var sortOrder: Int

    init(id: String, name: String, kind: String, budget: Int = 0, archived: Bool = false, sortOrder: Int) {
        self.id = id
        self.name = name
        self.kind = kind
        self.budget = budget
        self.archived = archived
        self.sortOrder = sortOrder
    }
}

enum Limits {
    static let noteMax = 120
    static let nameMax = 30
}

enum Defaults {
    /// Same ids as the web app, so backups move between the two.
    static func categories() -> [EntryCategory] {
        let expense = ["Food & dining", "Groceries", "Transport", "Bills & utilities", "Shopping", "Health",
                       "Entertainment", "Education", "Family", "Other"]
        let income = ["Salary", "Business", "Gifts", "Other income"]
        var out: [EntryCategory] = investmentCategories()
        for (i, name) in expense.enumerated() {
            out.append(EntryCategory(id: "exp-" + slug(name), name: name, kind: "expense", sortOrder: i))
        }
        for (i, name) in income.enumerated() {
            out.append(EntryCategory(id: "inc-" + slug(name), name: name, kind: "income", sortOrder: 100 + i))
        }
        return out.sorted { $0.sortOrder < $1.sortOrder }
    }

    static func investmentCategories() -> [EntryCategory] {
        let names = ["Plot instalment", "BC (committee)", "Gold", "Stocks & funds", "Savings"]
        return names.enumerated().map { i, name in
            EntryCategory(id: "inv-" + slug(name), name: name, kind: EntryKind.investment.rawValue, sortOrder: 200 + i)
        }
    }

    /// Existing installs and older backups have no investment categories: add the defaults once.
    static func ensureInvestmentCategories(_ context: ModelContext) {
        let kind = EntryKind.investment.rawValue
        let existing = (try? context.fetchCount(FetchDescriptor<EntryCategory>(predicate: #Predicate { $0.kind == kind }))) ?? 0
        guard existing == 0 else { return }
        investmentCategories().forEach { context.insert($0) }
        try? context.save()
    }

    /// Card was removed: existing card entries become bank, once.
    static func migrateCardToBank(_ context: ModelContext) {
        let card = PayMethod.card.rawValue
        guard let old = try? context.fetch(FetchDescriptor<Entry>(predicate: #Predicate { $0.method == card })),
              !old.isEmpty else { return }
        old.forEach { $0.method = PayMethod.bank.rawValue }
        try? context.save()
    }

    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for ch in lowered {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
