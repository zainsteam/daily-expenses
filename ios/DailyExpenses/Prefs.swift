import Foundation
import Observation

/// Small settings, kept in UserDefaults on this iPhone.
@Observable
final class Prefs {
    var setupDone: Bool { didSet { store.set(setupDone, forKey: "setupDone") } }
    var currency: String { didSet { store.set(currency, forKey: "currency") } }
    var overallBudget: Int { didSet { store.set(overallBudget, forKey: "overallBudget") } }
    var lastMethodExpense: String { didSet { store.set(lastMethodExpense, forKey: "lastMethodExpense") } }
    var lastMethodIncome: String { didSet { store.set(lastMethodIncome, forKey: "lastMethodIncome") } }
    var lastCategoryExpense: String { didSet { store.set(lastCategoryExpense, forKey: "lastCategoryExpense") } }
    var lastCategoryIncome: String { didSet { store.set(lastCategoryIncome, forKey: "lastCategoryIncome") } }
    var lastMethodInvestment: String { didSet { store.set(lastMethodInvestment, forKey: "lastMethodInvestment") } }
    var lastCategoryInvestment: String { didSet { store.set(lastCategoryInvestment, forKey: "lastCategoryInvestment") } }
    var lastBackupAt: Int { didSet { store.set(lastBackupAt, forKey: "lastBackupAt") } }
    var lastChangeAt: Int { didSet { store.set(lastChangeAt, forKey: "lastChangeAt") } }
    var createdAt: Int { didSet { store.set(createdAt, forKey: "createdAt") } }
    /// Starting balances, as of the start of `startDate` ("yyyy-MM-dd"; empty means not set).
    var startCash: Int { didSet { store.set(startCash, forKey: "startCash") } }
    var startBank: Int { didSet { store.set(startBank, forKey: "startBank") } }
    var startDate: String { didSet { store.set(startDate, forKey: "startDate") } }

    @ObservationIgnored private let store = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        setupDone = d.bool(forKey: "setupDone")
        currency = d.string(forKey: "currency") ?? "USD"
        overallBudget = d.integer(forKey: "overallBudget")
        lastMethodExpense = d.string(forKey: "lastMethodExpense") ?? PayMethod.cash.rawValue
        lastMethodIncome = d.string(forKey: "lastMethodIncome") ?? PayMethod.bank.rawValue
        lastCategoryExpense = d.string(forKey: "lastCategoryExpense") ?? ""
        lastCategoryIncome = d.string(forKey: "lastCategoryIncome") ?? ""
        lastMethodInvestment = d.string(forKey: "lastMethodInvestment") ?? PayMethod.bank.rawValue
        lastCategoryInvestment = d.string(forKey: "lastCategoryInvestment") ?? ""
        lastBackupAt = d.integer(forKey: "lastBackupAt")
        lastChangeAt = d.integer(forKey: "lastChangeAt")
        createdAt = d.integer(forKey: "createdAt")
        startCash = d.integer(forKey: "startCash")
        startBank = d.integer(forKey: "startBank")
        startDate = d.string(forKey: "startDate") ?? ""
    }

    var hasStartingBalance: Bool { !startDate.isEmpty }

    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    func lastMethod(_ kind: EntryKind) -> PayMethod {
        switch kind {
        case .expense: return (PayMethod(rawValue: lastMethodExpense) ?? .cash).account
        case .income: return (PayMethod(rawValue: lastMethodIncome) ?? .bank).account
        case .investment, .withdrawal: return (PayMethod(rawValue: lastMethodInvestment) ?? .bank).account
        case .transfer: return .bank // most transfers are taking cash out of the bank
        }
    }

    func lastCategory(_ kind: EntryKind) -> String {
        switch kind {
        case .expense: return lastCategoryExpense
        case .income: return lastCategoryIncome
        case .investment, .withdrawal: return lastCategoryInvestment
        case .transfer: return ""
        }
    }

    func remember(kind: EntryKind, method: PayMethod, categoryId: String) {
        switch kind {
        case .transfer:
            break
        case .expense:
            lastMethodExpense = method.rawValue
            lastCategoryExpense = categoryId
        case .income:
            lastMethodIncome = method.rawValue
            lastCategoryIncome = categoryId
        case .investment, .withdrawal:
            lastMethodInvestment = method.rawValue
            lastCategoryInvestment = categoryId
        }
    }

    /// Marks unsaved changes for the backup reminder.
    func touch() { lastChangeAt = Prefs.nowMs() }

    /// Due once there are changes since the last backup file and it is a week old
    /// (or there has never been one and at least ten entries exist).
    func backupDue(entryCount: Int) -> Bool {
        guard lastChangeAt > lastBackupAt, entryCount > 0 else { return false }
        if lastBackupAt > 0 { return Prefs.nowMs() - lastBackupAt >= 7 * 86_400_000 }
        return entryCount >= 10
    }
}
