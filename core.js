/*
 * core.js: pure logic for Daily Expenses. No DOM access, so it can be unit tested in Node.
 * In the browser it is loaded as a classic script and exposed as window.Core.
 */
(function (root, factory) {
  'use strict';
  const api = factory(root);
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.Core = api;
})(typeof self !== 'undefined' ? self : globalThis, function (root) {
  'use strict';

  // Money is stored as integer hundredths ("minor units") so totals never drift.
  const SCALE = 100;
  const MAX_AMOUNT = 99999999999; // 999,999,999.99
  const TYPES = ['expense', 'income'];
  const METHODS = ['cash', 'card', 'bank'];
  const METHOD_LABELS = { cash: 'Cash', card: 'Card', bank: 'Bank' };
  const BACKUP_APP = 'daily-expenses';
  const BACKUP_VERSION = 1;
  const NOTE_MAX = 120;
  const NAME_MAX = 30;
  const DAY_MS = 86400000;

  // Only used to pre-select a currency on first launch. The user confirms it.
  const REGION_CURRENCY = {
    US: 'USD', GB: 'GBP', IE: 'EUR', DE: 'EUR', FR: 'EUR', ES: 'EUR', IT: 'EUR', NL: 'EUR', BE: 'EUR',
    AT: 'EUR', PT: 'EUR', FI: 'EUR', GR: 'EUR', IN: 'INR', PK: 'PKR', BD: 'BDT', LK: 'LKR', NP: 'NPR',
    AE: 'AED', SA: 'SAR', QA: 'QAR', KW: 'KWD', OM: 'OMR', BH: 'BHD', EG: 'EGP', TR: 'TRY', NG: 'NGN',
    KE: 'KES', ZA: 'ZAR', CA: 'CAD', AU: 'AUD', NZ: 'NZD', JP: 'JPY', CN: 'CNY', KR: 'KRW', SG: 'SGD',
    MY: 'MYR', ID: 'IDR', PH: 'PHP', TH: 'THB', VN: 'VND', BR: 'BRL', MX: 'MXN', AR: 'ARS', CH: 'CHF',
    SE: 'SEK', NO: 'NOK', DK: 'DKK', PL: 'PLN', UA: 'UAH'
  };
  const FALLBACK_CURRENCIES = ['AED', 'AUD', 'BDT', 'BRL', 'CAD', 'CHF', 'CNY', 'EGP', 'EUR', 'GBP', 'IDR',
    'INR', 'JPY', 'KES', 'MXN', 'MYR', 'NGN', 'PHP', 'PKR', 'SAR', 'SGD', 'TRY', 'USD', 'ZAR'];

  const pad2 = (n) => String(n).padStart(2, '0');
  const isNonNegInt = (n) => Number.isSafeInteger(n) && n >= 0;

  /* ---------- Dates: always local calendar dates, never UTC ---------- */

  function toISODate(d) {
    return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
  }

  function todayISO(now) {
    return toISODate(now === undefined ? new Date() : new Date(now));
  }

  // new Date('2026-11-12') is parsed as UTC midnight and can land on the previous local day.
  function parseISODate(iso) {
    const p = String(iso).split('-').map(Number);
    return new Date(p[0], p[1] - 1, p[2]);
  }

  function isValidISODate(s) {
    return typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && toISODate(parseISODate(s)) === s;
  }

  function monthOf(iso) {
    return String(iso).slice(0, 7);
  }

  function addMonths(month, delta) {
    const p = month.split('-').map(Number);
    return toISODate(new Date(p[0], p[1] - 1 + delta, 1)).slice(0, 7);
  }

  function daysInMonth(month) {
    const p = month.split('-').map(Number);
    return new Date(p[0], p[1], 0).getDate();
  }

  function addDays(iso, delta) {
    const d = parseISODate(iso);
    d.setDate(d.getDate() + delta);
    return toISODate(d);
  }

  function monthLabel(month, locale) {
    const p = month.split('-').map(Number);
    return new Intl.DateTimeFormat(locale, { month: 'long', year: 'numeric' }).format(new Date(p[0], p[1] - 1, 1));
  }

  function dayLabel(iso, today, locale) {
    if (iso === today) return 'Today';
    if (iso === addDays(today, -1)) return 'Yesterday';
    const opts = { weekday: 'short', day: 'numeric', month: 'short' };
    if (iso.slice(0, 4) !== today.slice(0, 4)) opts.year = 'numeric';
    return new Intl.DateTimeFormat(locale, opts).format(parseISODate(iso));
  }

  // "today", "yesterday", "5 days ago", or a date once it is more than two months old.
  function relativeDays(ts, now) {
    const days = Math.round((parseISODate(todayISO(now)) - parseISODate(todayISO(ts))) / DAY_MS);
    if (days <= 0) return 'today';
    if (days === 1) return 'yesterday';
    if (days < 60) return days + ' days ago';
    return new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short', year: 'numeric' }).format(new Date(ts));
  }

  /* ---------- Money ---------- */

  const digitsCache = new Map();
  function currencyDigits(currency) {
    if (!digitsCache.has(currency)) {
      let digits = 2;
      try {
        digits = new Intl.NumberFormat('en', { style: 'currency', currency: currency }).resolvedOptions().maximumFractionDigits;
      } catch (e) {
        digits = 2;
      }
      digitsCache.set(currency, digits);
    }
    return digitsCache.get(currency);
  }

  const formatCache = new Map();
  function formatter(currency, digits) {
    const key = currency + ':' + digits;
    let f = formatCache.get(key);
    if (!f) {
      try {
        f = new Intl.NumberFormat(undefined, { style: 'currency', currency: currency, minimumFractionDigits: digits, maximumFractionDigits: digits });
      } catch (e) {
        f = new Intl.NumberFormat(undefined, { minimumFractionDigits: digits, maximumFractionDigits: digits });
      }
      formatCache.set(key, f);
    }
    return f;
  }

  // Whole amounts drop the decimals (Rs 1,250 rather than Rs 1,250.00).
  function formatMoney(minor, currency) {
    const digits = minor % SCALE === 0 || currencyDigits(currency) === 0 ? 0 : 2;
    return formatter(currency, digits).format(minor / SCALE);
  }

  function currencySymbol(currency) {
    try {
      const part = formatter(currency, 0).formatToParts(0).find((p) => p.type === 'currency');
      return part ? part.value : currency;
    } catch (e) {
      return currency;
    }
  }

  // Accepts "1250", "1,250", "12.5", "12,50", "1.234,56", "1,234.56", "50.000", "1.500.000".
  // Returns minor units or NaN. Parsed as a string, so 0.005 becomes 1 rather than suffering binary rounding.
  // A lone dot followed by exactly three digits ("50.000") is a thousands separator, the same rule as
  // "50,000", unless the currency really has three decimals (pass digits = 3, e.g. KWD "1.250").
  function parseAmount(input, digits) {
    let s = String(input == null ? '' : input).trim().replace(/[\s\u00a0\u202f']/g, '');
    if (!s) return NaN;
    const lastDot = s.lastIndexOf('.');
    const lastComma = s.lastIndexOf(',');
    if (lastDot !== -1 && lastComma !== -1) {
      s = lastComma > lastDot ? s.replace(/\./g, '').replace(',', '.') : s.replace(/,/g, '');
    } else if (lastComma !== -1) {
      s = /^\d+,\d{1,2}$/.test(s) ? s.replace(',', '.') : s.replace(/,/g, '');
    } else if (lastDot !== -1 && /^[1-9]\d{0,2}(\.\d{3})+$/.test(s) && (s.indexOf('.') !== lastDot || digits !== 3)) {
      s = s.replace(/\./g, '');
    }
    const m = /^(\d*)(?:\.(\d*))?$/.exec(s);
    if (!m || (!m[1] && !m[2])) return NaN;
    const whole = m[1] || '0';
    const frac = m[2] || '';
    if (whole.length > 12) return NaN;
    let minor = Number(whole) * SCALE + Number((frac + '00').slice(0, 2));
    if (frac.length > 2 && Number(frac[2]) >= 5) minor += 1;
    return minor;
  }

  // Value for an input field: "" for zero, "12.5", "1250".
  function minorToInput(minor) {
    if (!minor) return '';
    const a = Math.abs(minor);
    const frac = a % SCALE;
    return (minor < 0 ? '-' : '') + Math.floor(a / SCALE) + (frac ? '.' + pad2(frac).replace(/0$/, '') : '');
  }

  // Plain decimal for CSV: "1250.00".
  function minorToDecimal(minor) {
    const a = Math.abs(minor);
    return (minor < 0 ? '-' : '') + Math.floor(a / SCALE) + '.' + pad2(a % SCALE);
  }

  // Parses a typed amount for the given currency. Returns { value } or { error }; empty input gives value NaN.
  function readAmount(input, currency) {
    const digits = currencyDigits(currency);
    const value = parseAmount(input, digits);
    if (Number.isFinite(value) && digits === 0 && value % SCALE !== 0) {
      return { value: NaN, error: 'Amounts in ' + currency + ' don’t have decimals.' };
    }
    return { value: value };
  }

  /* ---------- Summaries ---------- */

  function byNewest(a, b) {
    if (a.date !== b.date) return a.date < b.date ? 1 : -1;
    return (b.createdAt || 0) - (a.createdAt || 0);
  }

  function budgetLine(limit, spent) {
    const ratio = limit > 0 ? spent / limit : 0;
    return { limit: limit, spent: spent, left: limit - spent, ratio: ratio, status: ratio > 1 ? 'over' : ratio >= 0.8 ? 'warn' : 'ok' };
  }

  function summarizeMonth(transactions, month, categories, settings, today) {
    const days = daysInMonth(month);
    const daily = new Array(days).fill(0);
    const byCat = new Map();
    const byMethod = { cash: 0, card: 0, bank: 0 };
    let income = 0;
    let expense = 0;
    let todayExpense = 0;
    let count = 0;

    for (const t of transactions) {
      if (t.date.slice(0, 7) !== month) continue;
      count++;
      if (t.type === 'income') {
        income += t.amount;
        continue;
      }
      expense += t.amount;
      byCat.set(t.categoryId, (byCat.get(t.categoryId) || 0) + t.amount);
      if (Object.prototype.hasOwnProperty.call(byMethod, t.method)) byMethod[t.method] += t.amount;
      const day = Number(t.date.slice(8, 10));
      if (day >= 1 && day <= days) daily[day - 1] += t.amount;
      if (t.date === today) todayExpense += t.amount;
    }

    const catMap = new Map(categories.map((c) => [c.id, c]));
    const categoryRows = Array.from(byCat, ([id, amount]) => ({
      id: id,
      name: catMap.has(id) ? catMap.get(id).name : 'Unknown category',
      amount: amount,
      share: expense ? amount / expense : 0
    })).sort((a, b) => b.amount - a.amount);

    const budgetRows = categories
      .filter((c) => c.type === 'expense' && !c.archived && c.budget > 0)
      .map((c) => Object.assign({ id: c.id, name: c.name }, budgetLine(c.budget, byCat.get(c.id) || 0)))
      .sort((a, b) => b.ratio - a.ratio);

    const thisMonth = today.slice(0, 7);
    const elapsedDays = month < thisMonth ? days : month === thisMonth ? Number(today.slice(8, 10)) : 0;
    const overallLimit = settings && settings.overallBudget > 0 ? settings.overallBudget : 0;
    const overall = overallLimit ? budgetLine(overallLimit, expense) : null;
    let pace = null;
    if (overall && month === thisMonth) {
      const daysLeft = days - elapsedDays + 1; // today counts as a day you can still spend
      pace = { daysLeft: daysLeft, perDay: overall.left > 0 ? Math.floor(overall.left / daysLeft) : 0 };
    }

    return {
      month: month,
      days: days,
      daily: daily,
      count: count,
      income: income,
      expense: expense,
      net: income - expense,
      todayExpense: todayExpense,
      elapsedDays: elapsedDays,
      categoryRows: categoryRows,
      budgetRows: budgetRows,
      byMethod: byMethod,
      overall: overall,
      pace: pace,
      dailyAllowance: overallLimit ? Math.round(overallLimit / days) : 0
    };
  }

  function filterTransactions(transactions, f) {
    return transactions.filter((t) =>
      (!f.month || t.date.slice(0, 7) === f.month) &&
      (!f.type || f.type === 'all' || t.type === f.type) &&
      (!f.method || f.method === 'all' || t.method === f.method) &&
      (!f.category || f.category === 'all' || t.categoryId === f.category));
  }

  function groupByDate(transactions) {
    const groups = [];
    for (const t of transactions.slice().sort(byNewest)) {
      let g = groups[groups.length - 1];
      if (!g || g.date !== t.date) {
        g = { date: t.date, items: [], expense: 0, income: 0 };
        groups.push(g);
      }
      g.items.push(t);
      g[t.type] += t.amount;
    }
    return groups;
  }

  function recent(transactions, month, n) {
    return transactions.filter((t) => t.date.slice(0, 7) === month).sort(byNewest).slice(0, n);
  }

  /* ---------- CSV ---------- */

  function csvCell(value) {
    let s = value == null ? '' : String(value);
    if (/^[=+\-@\t\r]/.test(s)) s = "'" + s; // keeps spreadsheets from running text as a formula
    return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  function toCSV(transactions, categories, currency) {
    const names = new Map(categories.map((c) => [c.id, c.name]));
    const rows = [['Date', 'Type', 'Category', 'Method', 'Amount', 'Currency', 'Note']];
    transactions.slice().sort((a, b) => byNewest(b, a)).forEach((t) => {
      rows.push([
        t.date,
        t.type === 'income' ? 'Income' : 'Expense',
        names.get(t.categoryId) || 'Unknown category',
        METHOD_LABELS[t.method] || t.method,
        minorToDecimal(t.amount),
        currency,
        t.note || ''
      ]);
    });
    // The BOM makes Excel read non-English notes correctly.
    return '\uFEFF' + rows.map((r) => r.map(csvCell).join(',')).join('\r\n') + '\r\n';
  }

  /* ---------- Data shapes, backup and restore ---------- */

  function normalizeSettings(s) {
    const src = s && typeof s === 'object' ? s : {};
    const lc = src.lastCategory && typeof src.lastCategory === 'object' ? src.lastCategory : {};
    const lm = src.lastMethod && typeof src.lastMethod === 'object' ? src.lastMethod : {};
    const isMethod = (m) => METHODS.indexOf(m) !== -1;
    return {
      currency: typeof src.currency === 'string' && /^[A-Z]{3}$/.test(src.currency) ? src.currency : 'USD',
      overallBudget: isNonNegInt(src.overallBudget) && src.overallBudget <= MAX_AMOUNT ? src.overallBudget : 0,
      // Remembered per type: spending is usually cash or card, income usually lands in the bank.
      lastMethod: {
        expense: isMethod(lm.expense) ? lm.expense : isMethod(src.lastMethod) ? src.lastMethod : 'cash',
        income: isMethod(lm.income) ? lm.income : 'bank'
      },
      lastCategory: {
        expense: typeof lc.expense === 'string' ? lc.expense : null,
        income: typeof lc.income === 'string' ? lc.income : null
      },
      lastBackupAt: isNonNegInt(src.lastBackupAt) ? src.lastBackupAt : 0,
      lastChangeAt: isNonNegInt(src.lastChangeAt) ? src.lastChangeAt : 0,
      createdAt: isNonNegInt(src.createdAt) ? src.createdAt : 0
    };
  }

  function normalizeCategory(c) {
    if (!c || typeof c !== 'object') return null;
    if (typeof c.id !== 'string' || !c.id || c.id.length > 64) return null;
    const name = typeof c.name === 'string' ? c.name.trim().replace(/\s+/g, ' ').slice(0, NAME_MAX) : '';
    if (!name || TYPES.indexOf(c.type) === -1) return null;
    const budget = c.type === 'expense' && isNonNegInt(c.budget) && c.budget <= MAX_AMOUNT ? c.budget : 0;
    return { id: c.id, name: name, type: c.type, budget: budget, archived: c.archived === true };
  }

  function normalizeTransaction(t) {
    if (!t || typeof t !== 'object') return null;
    if (typeof t.id !== 'string' || !t.id || t.id.length > 64) return null;
    if (TYPES.indexOf(t.type) === -1 || METHODS.indexOf(t.method) === -1) return null;
    if (!Number.isSafeInteger(t.amount) || t.amount <= 0 || t.amount > MAX_AMOUNT) return null;
    if (typeof t.categoryId !== 'string' || !isValidISODate(t.date)) return null;
    return {
      id: t.id,
      type: t.type,
      amount: t.amount,
      categoryId: t.categoryId,
      method: t.method,
      date: t.date,
      note: typeof t.note === 'string' ? t.note.slice(0, NOTE_MAX) : '',
      createdAt: isNonNegInt(t.createdAt) ? t.createdAt : 0,
      updatedAt: isNonNegInt(t.updatedAt) ? t.updatedAt : 0
    };
  }

  function buildBackup(data, now) {
    return {
      app: BACKUP_APP,
      version: BACKUP_VERSION,
      exportedAt: new Date(now).toISOString(),
      settings: data.settings,
      categories: data.categories,
      transactions: data.transactions
    };
  }

  // Strict on purpose: a damaged file is rejected whole instead of half-restored.
  function validateBackup(obj) {
    const fail = (error) => ({ ok: false, error: error });
    if (!obj || typeof obj !== 'object' || Array.isArray(obj) || obj.app !== BACKUP_APP) {
      return fail('That file isn’t a backup from this app.');
    }
    if (!Number.isInteger(obj.version) || obj.version < 1) return fail('The backup has no version number.');
    if (obj.version > BACKUP_VERSION) return fail('This backup comes from a newer version of the app. Update the app first.');
    if (!Array.isArray(obj.categories) || !Array.isArray(obj.transactions)) return fail('The backup is missing its data.');

    const categories = [];
    const catById = new Map();
    for (const raw of obj.categories) {
      const c = normalizeCategory(raw);
      if (!c) return fail('The backup has a damaged category.');
      if (catById.has(c.id)) return fail('The backup lists the same category twice.');
      catById.set(c.id, c);
      categories.push(c);
    }
    if (!categories.some((c) => c.type === 'expense') || !categories.some((c) => c.type === 'income')) {
      return fail('The backup needs at least one expense and one income category.');
    }

    const transactions = [];
    const seen = new Set();
    for (let i = 0; i < obj.transactions.length; i++) {
      const t = normalizeTransaction(obj.transactions[i]);
      if (!t) return fail('Entry ' + (i + 1) + ' in the backup is damaged.');
      const cat = catById.get(t.categoryId);
      if (!cat || cat.type !== t.type) return fail('Entry ' + (i + 1) + ' uses a category that isn’t in the backup.');
      if (seen.has(t.id)) return fail('The backup lists the same entry twice.');
      seen.add(t.id);
      transactions.push(t);
    }

    return {
      ok: true,
      data: {
        exportedAt: typeof obj.exportedAt === 'string' ? obj.exportedAt : null,
        settings: normalizeSettings(obj.settings),
        categories: categories,
        transactions: transactions
      }
    };
  }

  function slug(name) {
    return name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
  }

  function defaultCategories() {
    const expense = ['Food & dining', 'Groceries', 'Transport', 'Bills & utilities', 'Shopping', 'Health',
      'Entertainment', 'Education', 'Family', 'Other'];
    const income = ['Salary', 'Business', 'Gifts', 'Other income'];
    return expense.map((name) => ({ id: 'exp-' + slug(name), name: name, type: 'expense', budget: 0, archived: false }))
      .concat(income.map((name) => ({ id: 'inc-' + slug(name), name: name, type: 'income', budget: 0, archived: false })));
  }

  function guessCurrency(languages) {
    const list = Array.isArray(languages) ? languages : [];
    for (const tag of list) {
      if (typeof tag !== 'string') continue;
      let region = '';
      try {
        region = new Intl.Locale(tag).maximize().region || '';
      } catch (e) {
        const m = /[-_]([A-Za-z]{2})(?:[-_]|$)/.exec(tag);
        region = m ? m[1].toUpperCase() : '';
      }
      if (REGION_CURRENCY[region]) return REGION_CURRENCY[region];
    }
    return 'USD';
  }

  // A reminder is due once there are unsaved changes and the last backup is a week old
  // (or there has never been one and at least ten entries exist).
  function backupStatus(settings, txCount, now) {
    const last = settings.lastBackupAt || 0;
    const unsaved = (settings.lastChangeAt || 0) > last;
    let due = false;
    if (unsaved && txCount > 0) due = last ? now - last >= 7 * DAY_MS : txCount >= 10;
    return { due: due, last: last, unsaved: unsaved };
  }

  function uid() {
    const c = root.crypto;
    if (c && typeof c.randomUUID === 'function') {
      try {
        return c.randomUUID();
      } catch (e) {
        /* not a secure context: use the fallback */
      }
    }
    let rand;
    if (c && typeof c.getRandomValues === 'function') {
      const buf = new Uint32Array(4);
      c.getRandomValues(buf);
      rand = Array.from(buf, (n) => n.toString(36)).join('');
    } else {
      rand = Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
    }
    return Date.now().toString(36) + '-' + rand;
  }

  return {
    SCALE: SCALE,
    MAX_AMOUNT: MAX_AMOUNT,
    TYPES: TYPES,
    METHODS: METHODS,
    METHOD_LABELS: METHOD_LABELS,
    NOTE_MAX: NOTE_MAX,
    NAME_MAX: NAME_MAX,
    BACKUP_APP: BACKUP_APP,
    BACKUP_VERSION: BACKUP_VERSION,
    FALLBACK_CURRENCIES: FALLBACK_CURRENCIES,
    toISODate: toISODate,
    todayISO: todayISO,
    parseISODate: parseISODate,
    isValidISODate: isValidISODate,
    monthOf: monthOf,
    addMonths: addMonths,
    daysInMonth: daysInMonth,
    addDays: addDays,
    monthLabel: monthLabel,
    dayLabel: dayLabel,
    relativeDays: relativeDays,
    currencyDigits: currencyDigits,
    formatMoney: formatMoney,
    currencySymbol: currencySymbol,
    parseAmount: parseAmount,
    readAmount: readAmount,
    minorToInput: minorToInput,
    minorToDecimal: minorToDecimal,
    budgetLine: budgetLine,
    summarizeMonth: summarizeMonth,
    filterTransactions: filterTransactions,
    groupByDate: groupByDate,
    recent: recent,
    csvCell: csvCell,
    toCSV: toCSV,
    normalizeSettings: normalizeSettings,
    normalizeCategory: normalizeCategory,
    normalizeTransaction: normalizeTransaction,
    buildBackup: buildBackup,
    validateBackup: validateBackup,
    defaultCategories: defaultCategories,
    guessCurrency: guessCurrency,
    backupStatus: backupStatus,
    uid: uid
  };
});
