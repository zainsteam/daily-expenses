# Daily Expenses for iPhone

Native SwiftUI app. Entries are stored with SwiftData inside the app on your iPhone: no server, no account.
They are included in the iPhone's own iCloud or computer backup, and Settings > Back up now saves a JSON file
(the same format as the web app, so backups move between the two).

Requires iOS 17 or later. Built with Xcode 26.1.

## Put it on your iPhone (free Apple ID)

1. Open `DailyExpenses.xcodeproj` in Xcode.
2. Xcode > Settings > Accounts > `+` > Apple ID, and sign in.
3. Click the **DailyExpenses** project, then the **DailyExpenses** target > **Signing & Capabilities**.
   Keep "Automatically manage signing" on and set **Team** to your name (Personal Team).
   If Xcode says the bundle identifier is taken, change `com.zainsteam.expenses.ledger` to something unique.
4. Plug the iPhone in with a cable and tap **Trust** on the phone.
5. On the iPhone: Settings > Privacy & Security > **Developer Mode** > on, then restart when asked.
6. In Xcode, pick your iPhone at the top of the window and press **Run** (⌘R).
7. The first time, the phone blocks the app: Settings > General > **VPN & Device Management** >
   your Apple ID > **Trust**. Then open the app.

### The 7-day limit

With a free Apple ID, the app stops opening after 7 days. Your data is not lost: plug the phone in and press
Run in Xcode again, and it opens with everything still there. **Don't delete the app** to fix it, because
deleting the app deletes its data.

A paid Apple Developer membership ($99 a year) makes each install last a year and allows TestFlight
installs over the air, without a cable.

## Build from the command line

```
xcodebuild -project DailyExpenses.xcodeproj -scheme DailyExpenses \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath build build
```

## Files

| File | What it does |
| --- | --- |
| `DailyExpensesApp.swift` | App entry, data container, setup or main screen |
| `Models.swift` | `Entry` and `EntryCategory` (SwiftData), default categories |
| `Prefs.swift` | Small settings in UserDefaults, backup reminder |
| `Money.swift` | Amount parsing and formatting, local dates |
| `Summary.swift` | Monthly totals, budgets, pace |
| `OverviewView.swift`, `HistoryView.swift`, `BudgetsView.swift`, `SettingsView.swift` | The four tabs |
| `EntryEditor.swift` | Add and edit sheet |
| `Backup.swift` | Backup file, restore checks, CSV export |
