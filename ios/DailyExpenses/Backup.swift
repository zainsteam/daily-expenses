import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Same JSON shape as the web app's backup, so files move between the two.
struct BackupFile: Codable {
    var app: String
    var version: Int
    var exportedAt: String?
    var settings: BackupSettings?
    var categories: [BackupCategory]
    var transactions: [BackupEntry]
}

struct BackupSettings: Codable {
    var currency: String?
    var overallBudget: Int?
    var lastMethod: [String: String]?
    var lastCategory: [String: String?]?
    var lastBackupAt: Int?
    var lastChangeAt: Int?
    var createdAt: Int?
    var startCash: Int?
    var startBank: Int?
    var startDate: String?

    init(currency: String?, overallBudget: Int?, lastMethod: [String: String]?, lastCategory: [String: String?]?,
         lastBackupAt: Int?, lastChangeAt: Int?, createdAt: Int?,
         startCash: Int? = nil, startBank: Int? = nil, startDate: String? = nil) {
        self.startCash = startCash
        self.startBank = startBank
        self.startDate = startDate
        self.currency = currency
        self.overallBudget = overallBudget
        self.lastMethod = lastMethod
        self.lastCategory = lastCategory
        self.lastBackupAt = lastBackupAt
        self.lastChangeAt = lastChangeAt
        self.createdAt = createdAt
    }

    // Lenient: a settings field in an unexpected shape is dropped, not fatal.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currency = try? c.decodeIfPresent(String.self, forKey: .currency)
        overallBudget = try? c.decodeIfPresent(Int.self, forKey: .overallBudget)
        lastMethod = try? c.decodeIfPresent([String: String].self, forKey: .lastMethod)
        lastCategory = try? c.decodeIfPresent([String: String?].self, forKey: .lastCategory)
        lastBackupAt = try? c.decodeIfPresent(Int.self, forKey: .lastBackupAt)
        lastChangeAt = try? c.decodeIfPresent(Int.self, forKey: .lastChangeAt)
        createdAt = try? c.decodeIfPresent(Int.self, forKey: .createdAt)
        startCash = try? c.decodeIfPresent(Int.self, forKey: .startCash)
        startBank = try? c.decodeIfPresent(Int.self, forKey: .startBank)
        startDate = try? c.decodeIfPresent(String.self, forKey: .startDate)
    }
}

struct BackupCategory: Codable {
    var id: String
    var name: String
    var type: String
    var budget: Int?
    var archived: Bool?
}

struct BackupEntry: Codable {
    var id: String
    var type: String
    var amount: Int
    var categoryId: String
    var method: String
    var date: String
    var note: String?
    var createdAt: Int?
    var updatedAt: Int?
}

enum Backup {
    static let appId = "daily-expenses"
    static let version = 1

    enum Checked {
        case ok(BackupFile)
        case failed(String)
    }

    static func build(entries: [Entry], categories: [EntryCategory], prefs: Prefs, now: Int) -> BackupFile {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return BackupFile(
            app: appId,
            version: version,
            exportedAt: iso.string(from: Date(timeIntervalSince1970: Double(now) / 1000)),
            settings: BackupSettings(
                currency: prefs.currency,
                overallBudget: prefs.overallBudget,
                lastMethod: ["expense": prefs.lastMethodExpense, "income": prefs.lastMethodIncome,
                             "investment": prefs.lastMethodInvestment],
                lastCategory: ["expense": prefs.lastCategoryExpense.isEmpty ? nil : prefs.lastCategoryExpense,
                               "income": prefs.lastCategoryIncome.isEmpty ? nil : prefs.lastCategoryIncome,
                               "investment": prefs.lastCategoryInvestment.isEmpty ? nil : prefs.lastCategoryInvestment],
                lastBackupAt: prefs.lastBackupAt,
                lastChangeAt: prefs.lastChangeAt,
                createdAt: prefs.createdAt,
                startCash: prefs.hasStartingBalance ? prefs.startCash : nil,
                startBank: prefs.hasStartingBalance ? prefs.startBank : nil,
                startDate: prefs.hasStartingBalance ? prefs.startDate : nil),
            categories: categories.sorted { $0.sortOrder < $1.sortOrder }.map {
                BackupCategory(id: $0.id, name: $0.name, type: $0.kind, budget: $0.budget, archived: $0.archived)
            },
            transactions: entries.sorted { Ledger.byNewest($1, $0) }.map {
                BackupEntry(id: $0.id, type: $0.kind, amount: $0.amount, categoryId: $0.categoryId, method: $0.method,
                            date: $0.date, note: $0.note, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            })
    }

    static func encode(_ file: BackupFile) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(file)
    }

    private struct Head: Decodable {
        var app: String?
        var version: Int?
    }

    /// Strict on purpose: a damaged file is rejected whole instead of half-restored.
    static func check(_ data: Data) -> Checked {
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.app == appId else {
            return .failed("That file isn’t a backup from this app.")
        }
        guard let v = head.version, v >= 1 else { return .failed("The backup has no version number.") }
        if v > version { return .failed("This backup comes from a newer version of the app. Update the app first.") }
        guard var file = try? JSONDecoder().decode(BackupFile.self, from: data) else {
            return .failed("The backup is damaged.")
        }

        var catKind: [String: String] = [:]
        var cats: [BackupCategory] = []
        for var c in file.categories {
            let name = c.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            c.name = String(name.prefix(Limits.nameMax))
            let validKinds = [EntryKind.expense, .income, .investment].map(\.rawValue)
            guard !c.id.isEmpty, c.id.count <= 64, !c.name.isEmpty, validKinds.contains(c.type) else {
                return .failed("The backup has a damaged category.")
            }
            if catKind[c.id] != nil { return .failed("The backup lists the same category twice.") }
            let budget = c.budget ?? 0
            c.budget = c.type == "expense" && budget >= 0 && budget <= Money.maxAmount ? budget : 0
            catKind[c.id] = c.type
            cats.append(c)
        }
        if !cats.contains(where: { $0.type == "expense" }) || !cats.contains(where: { $0.type == "income" }) {
            return .failed("The backup needs at least one expense and one income category.")
        }

        var seen = Set<String>()
        var entries: [BackupEntry] = []
        for (i, var e) in file.transactions.enumerated() {
            guard !e.id.isEmpty, e.id.count <= 64, EntryKind(rawValue: e.type) != nil, PayMethod(rawValue: e.method) != nil,
                  e.amount > 0, e.amount <= Money.maxAmount, Day.isValid(e.date) else {
                return .failed("Entry \(i + 1) in the backup is damaged.")
            }
            guard let kind = EntryKind(rawValue: e.type) else { return .failed("Entry \(i + 1) in the backup is damaged.") }
            if kind.needsCategory {
                guard catKind[e.categoryId] == kind.categoryKind else {
                    return .failed("Entry \(i + 1) uses a category that isn’t in the backup.")
                }
            } else {
                e.categoryId = ""
            }
            // Card was removed from the app: card payments come from the bank.
            if e.method == PayMethod.card.rawValue { e.method = PayMethod.bank.rawValue }
            if !seen.insert(e.id).inserted { return .failed("The backup lists the same entry twice.") }
            e.note = String((e.note ?? "").prefix(Limits.noteMax))
            entries.append(e)
        }
        file.categories = cats
        file.transactions = entries
        return .ok(file)
    }

    // MARK: CSV

    static func csvCell(_ value: String) -> String {
        var s = value
        if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s } // stops spreadsheets running it as a formula
        if s.contains(where: { "\",\r\n".contains($0) }) { return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return s
    }

    static func csv(entries: [Entry], categories: [EntryCategory], currency: String) -> String {
        let names = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var rows = [["Date", "Type", "Category", "Method", "Amount", "Currency", "Note"]]
        for e in entries.sorted(by: { Ledger.byNewest($1, $0) }) {
            let transfer = e.entryKind == .transfer
            rows.append([e.date, e.entryKind.label,
                         transfer ? "" : (names[e.categoryId] ?? "Unknown category"),
                         transfer ? e.transferLabel : e.account.label,
                         Money.toDecimal(e.amount), currency, e.note])
        }
        // The BOM makes Excel read non-English notes correctly.
        return "\u{FEFF}" + rows.map { $0.map(csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
