# Daily Expenses

An offline-first PWA for logging daily spending and income, with monthly budgets and a cash/card/bank split.
Data is stored in IndexedDB on the device only. No server, no account, no third-party scripts.

## Files

| File | Purpose |
| --- | --- |
| `index.html`, `styles.css` | Markup and styles (light and dark mode) |
| `core.js` | Pure logic: money parsing/formatting, monthly summaries, CSV, backup validation |
| `store.js` | IndexedDB persistence; every save is one atomic transaction |
| `app.js` | UI controller |
| `sw.js` | Service worker: offline cache and the "new version" prompt |
| `manifest.webmanifest`, `icons/` | Install metadata and icons |

## Deploy on GitHub Pages

1. Create a **public** repository (free GitHub Pages needs a public repo; the code holds no personal data).
2. Upload every file, keeping the `icons/` folder.
3. Settings > Pages > Build and deployment: "Deploy from a branch", branch `main`, folder `/ (root)`, Save.
4. Open `https://<username>.github.io/<repo>/` on your phone and install it before logging anything.
   - iPhone: Safari > Share > Add to Home Screen
   - Android: Chrome menu > Install app

All paths are relative, so the app works from a repo subpath.

## Shipping a change

Bump `CACHE` in `sw.js` (`daily-expenses-v1` to `daily-expenses-v2`, and so on) every time you change any file.
The installed app shows "A new version is ready" and switches only when you tap Update now.
If you add a file, add it to `ASSETS` in `sw.js`, or offline mode breaks.

## Run locally

```
python3 -m http.server 8080
```

Open http://localhost:8080 (service workers only run on localhost or HTTPS).

## Data

- Back up from Settings > Back up now. On a phone this opens the share sheet, so you can save the JSON to Files or Drive.
- Restore replaces everything on the device and rejects damaged or foreign files without changing anything.
- On iPhone the home-screen app has its own storage, separate from Safari. Deleting the icon deletes its data.
- Amounts are stored as integer hundredths. Three-decimal currencies (KWD, BHD, OMR) are rounded to two decimals.
- Amounts accept `1,250`, `1.250`, `1.500.000`, `12.50` and `12,50`. A dot or comma followed by exactly three digits is read as a thousands separator, except for three-decimal currencies, where `1.250` means 1.25.
- Zero-decimal currencies (JPY, KRW, IDR, VND and so on) reject amounts with decimals.
