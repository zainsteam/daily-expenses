import Foundation

enum Money {
    static let scale = 100
    static let maxAmount = 99_999_999_999 // 999,999,999.99

    private static let zeroDecimal: Set<String> = ["BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG",
                                                   "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"]
    private static let threeDecimal: Set<String> = ["BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"]

    static func digits(_ currency: String) -> Int {
        if zeroDecimal.contains(currency) { return 0 }
        if threeDecimal.contains(currency) { return 3 }
        return 2
    }

    private static var formatters: [String: NumberFormatter] = [:]

    private static func formatter(_ currency: String, _ fraction: Int) -> NumberFormatter {
        let key = "\(currency):\(fraction)"
        if let f = formatters[key] { return f }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        formatters[key] = f
        return f
    }

    /// Whole amounts drop the decimals (Rs 1,250 rather than Rs 1,250.00).
    static func format(_ minor: Int, _ currency: String) -> String {
        let fraction = (minor % scale == 0 || digits(currency) == 0) ? 0 : 2
        let value = NSDecimalNumber(decimal: Decimal(minor) / Decimal(scale))
        return formatter(currency, fraction).string(from: value) ?? "\(currency) \(value)"
    }

    static func symbol(_ currency: String) -> String {
        formatter(currency, 0).currencySymbol ?? currency
    }

    /// Accepts "1250", "1,250", "12.5", "12,50", "1.234,56", "1,234.56", "50.000", "1.500.000".
    /// A dot or comma followed by exactly three digits is a thousands separator, except that a single dot
    /// stays a decimal point for three-decimal currencies (KWD "1.250"). Returns minor units, or nil.
    static func parse(_ input: String, digits: Int? = nil) -> Int? {
        var s = String(input.filter { !" \u{00a0}\u{202f}'".contains($0) })
        if s.isEmpty { return nil }
        let lastDot = s.lastIndex(of: ".")
        let lastComma = s.lastIndex(of: ",")
        if let dot = lastDot, let comma = lastComma {
            if comma > dot {
                s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if lastComma != nil {
            if s.wholeMatch(of: #/\d+,\d{1,2}/#) != nil {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if let dot = lastDot, s.wholeMatch(of: #/[1-9]\d{0,2}(\.\d{3})+/#) != nil,
                  s.firstIndex(of: ".") != dot || digits != 3 {
            s = s.replacingOccurrences(of: ".", with: "")
        }
        guard let m = s.wholeMatch(of: #/(\d*)(?:\.(\d*))?/#) else { return nil }
        let whole = String(m.1)
        let frac = m.2.map(String.init) ?? ""
        if whole.isEmpty && frac.isEmpty { return nil }
        if whole.count > 12 { return nil }
        var minor = (Int(whole.isEmpty ? "0" : whole) ?? 0) * scale + (Int(String((frac + "00").prefix(2))) ?? 0)
        if frac.count > 2, let third = frac.dropFirst(2).first?.wholeNumberValue, third >= 5 { minor += 1 }
        return minor
    }

    /// Parses a typed amount for a currency. `value` is nil for empty or unreadable input.
    static func read(_ input: String, currency: String) -> (value: Int?, error: String?) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return (nil, nil) }
        let d = digits(currency)
        guard let v = parse(trimmed, digits: d) else { return (nil, "That isn’t a valid amount.") }
        if d == 0 && v % scale != 0 { return (nil, "Amounts in \(currency) don’t have decimals.") }
        if v > maxAmount { return (nil, "That amount is too large.") }
        return (v, nil)
    }

    /// Value for a text field: "" for zero, "12.5", "1250".
    static func toInput(_ minor: Int) -> String {
        if minor == 0 { return "" }
        let whole = minor / scale
        let frac = minor % scale
        if frac == 0 { return "\(whole)" }
        var f = String(format: "%02d", frac)
        if f.hasSuffix("0") { f.removeLast() }
        return "\(whole).\(f)"
    }

    /// Plain decimal for CSV: "1250.00".
    static func toDecimal(_ minor: Int) -> String {
        "\(minor / scale).\(String(format: "%02d", minor % scale))"
    }
}

/// Local calendar dates as "yyyy-MM-dd" strings and months as "yyyy-MM".
enum Day {
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // Parsed at noon so a day with no midnight (some DST changes) still parses.
    private static let noonFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd HH"
        return f
    }()

    static func iso(_ date: Date) -> String { isoFormatter.string(from: date) }
    static func date(_ iso: String) -> Date { noonFormatter.date(from: iso + " 12") ?? Date() }
    static func today() -> String { iso(Date()) }
    static func month(_ iso: String) -> String { String(iso.prefix(7)) }

    static func isValid(_ s: String) -> Bool {
        guard s.count == 10, let d = noonFormatter.date(from: s + " 12") else { return false }
        return iso(d) == s
    }

    static func addMonths(_ month: String, _ delta: Int) -> String {
        let d = date(month + "-01")
        let moved = Calendar.current.date(byAdding: .month, value: delta, to: d) ?? d
        return String(iso(moved).prefix(7))
    }

    static func daysIn(_ month: String) -> Int {
        Calendar.current.range(of: .day, in: .month, for: date(month + "-01"))?.count ?? 30
    }

    static func monthLabel(_ month: String) -> String {
        date(month + "-01").formatted(.dateTime.month(.wide).year())
    }

    static func dayLabel(_ iso: String, today: String) -> String {
        if iso == today { return "Today" }
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: date(today)) ?? Date()
        if iso == self.iso(yesterday) { return "Yesterday" }
        let d = date(iso)
        if iso.prefix(4) != today.prefix(4) {
            return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    static func relative(_ ms: Int) -> String {
        let then = Date(timeIntervalSince1970: Double(ms) / 1000)
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: then),
                                                   to: Calendar.current.startOfDay(for: Date())).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 60 { return "\(days) days ago" }
        return then.formatted(date: .abbreviated, time: .omitted)
    }
}
