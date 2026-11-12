/*
 * app.js: UI for Daily Expenses.
 * Needs core.js (window.Core) and store.js (window.Store) loaded first.
 * State lives in memory; every change is written to IndexedDB first and only
 * applied to the screen once the write succeeds.
 */
(function () {
  'use strict';

  const C = window.Core;
  const S = window.Store;
  const APP_VERSION = '1.0.1';
  const VIEWS = ['home', 'history', 'budgets', 'settings'];
  const RECENT_COUNT = 4;

  const state = {
    settings: null,
    categories: [],
    transactions: [],
    view: 'home',
    month: C.monthOf(C.todayISO()),
    lastToday: C.todayISO(),
    filters: { type: 'all', method: 'all', category: 'all' },
    editingId: null,
    sheetToken: null, // a new object each time the sheet opens, null while it is closed
    saving: false,
    backupSnoozed: false,
    storageStatus: 'checking',
    installEvent: null,
    swReg: null,
    updating: false
  };

  let lastFocus = null;
  let toastTimer = 0;
  let currencyItems = null;

  /* ---------- helpers ---------- */

  const $ = (sel, root) => (root || document).querySelector(sel);
  const $$ = (sel, root) => Array.from((root || document).querySelectorAll(sel));
  const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (ch) => ESC[ch]);
  const money = (minor) => C.formatMoney(minor, state.settings.currency);
  const signedMoney = (minor) => (minor > 0 ? '+' : '') + money(minor);
  const catById = (id) => state.categories.find((c) => c.id === id) || null;
  const catName = (id) => {
    const c = catById(id);
    return c ? c.name : 'Unknown category';
  };
  const cleanText = (s, max) => String(s == null ? '' : s).trim().replace(/\s+/g, ' ').slice(0, max);
  const errMsg = (err) => (err && err.message ? err.message : String(err));
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : many);
  const media = (q) => !!(window.matchMedia && window.matchMedia(q).matches);
  const isStandalone = () => media('(display-mode: standalone)') || window.navigator.standalone === true;
  const checkedValue = (root, name) => {
    const el = root.querySelector('input[name="' + name + '"]:checked');
    return el ? el.value : '';
  };
  const setChecked = (root, name, value) => {
    $$('input[name="' + name + '"]', root).forEach((r) => {
      r.checked = r.value === value;
    });
  };

  /* ---------- boot ---------- */

  async function init() {
    bindEvents();
    registerServiceWorker();
    let data;
    try {
      data = await S.loadAll();
    } catch (err) {
      showFatal(err);
      return;
    }
    state.transactions = Array.isArray(data.transactions) ? data.transactions : [];
    state.categories = Array.isArray(data.categories) ? data.categories : [];
    if (!data.settings) {
      showSetup();
      return;
    }
    state.settings = C.normalizeSettings(data.settings);
    if (!state.categories.length) {
      state.categories = C.defaultCategories();
      S.commit({ kv: { categories: state.categories } }).catch(() => {});
    }
    start();
  }

  function start() {
    $('#setup').hidden = true;
    $('#app').hidden = false;
    render();
    S.persist().then((status) => {
      state.storageStatus = status;
      updateStorageText();
    });
  }

  function showFatal(err) {
    $('#app').hidden = true;
    $('#setup').hidden = true;
    $('#fatal-msg').textContent =
      'This browser isn’t letting the app store data, so nothing can be saved. ' +
      'If this is a private window, open the app in a normal one. (' + errMsg(err) + ')';
    $('#fatal').hidden = false;
  }

  function showSetup() {
    const langs = navigator.languages && navigator.languages.length ? Array.from(navigator.languages) : [navigator.language];
    $('#setup-currency').innerHTML = currencyOptions(C.guessCurrency(langs));
    $('#setup-install').hidden = isStandalone();
    $('#setup').hidden = false;
  }

  async function finishSetup(button) {
    const currency = $('#setup-currency').value || 'USD';
    const settings = C.normalizeSettings({ currency: currency, createdAt: Date.now() });
    const categories = C.defaultCategories();
    button.disabled = true;
    try {
      await S.commit({ kv: { settings: settings, categories: categories } });
    } catch (err) {
      toast('Couldn’t save your settings: ' + errMsg(err));
      return;
    } finally {
      button.disabled = false;
    }
    state.settings = settings;
    state.categories = categories;
    start();
  }

  /* ---------- rendering ---------- */

  function render() {
    if (!state.settings) return;
    VIEWS.forEach((v) => {
      $('#view-' + v).hidden = v !== state.view;
    });
    $$('.tab').forEach((t) => {
      if (t.dataset.view === state.view) t.setAttribute('aria-current', 'page');
      else t.removeAttribute('aria-current');
    });
    const monthView = state.view === 'home' || state.view === 'history';
    $('#month-nav').hidden = !monthView;
    const title = $('#page-title');
    title.hidden = monthView;
    title.textContent = state.view === 'budgets' ? 'Budgets' : 'Settings';
    $('#month-label').textContent = C.monthLabel(state.month);

    if (state.view === 'home') renderHome();
    else if (state.view === 'history') renderHistory();
    else if (state.view === 'budgets') renderBudgets();
    else renderSettings();
  }

  function renderHome() {
    const today = C.todayISO();
    const sum = C.summarizeMonth(state.transactions, state.month, state.categories, state.settings, today);
    const monthName = C.monthLabel(state.month);
    const thisMonth = C.monthOf(today);
    const isCurrent = state.month === thisMonth;
    const isPast = state.month < thisMonth;
    const out = [];

    const backup = C.backupStatus(state.settings, state.transactions.length, Date.now());
    if (backup.due && !state.backupSnoozed) {
      out.push(
        '<div class="notice" role="note"><p>' +
          (backup.last ? 'Last backup: ' + esc(C.relativeDays(backup.last, Date.now())) + '.' : 'You haven’t made a backup yet.') +
          ' Your entries are stored only on this device.</p>' +
          '<div class="btn-row">' +
          '<button type="button" class="btn small primary" data-action="backup">Back up now</button>' +
          '<button type="button" class="btn small quiet" data-action="snooze-backup">Later</button>' +
          '</div></div>'
      );
    }

    const notes = [];
    if (isCurrent) notes.push('<p>Spent today: <span class="num">' + esc(money(sum.todayExpense)) + '</span></p>');
    if (sum.overall) {
      const o = sum.overall;
      if (o.left < 0) {
        notes.push('<p class="over">' + esc(money(-o.left)) + ' over your ' + esc(money(o.limit)) + ' budget.</p>');
      } else if (isPast) {
        notes.push('<p>Finished ' + esc(money(o.left)) + ' under your ' + esc(money(o.limit)) + ' budget.</p>');
      } else if (sum.pace) {
        notes.push(
          '<p>' + esc(money(o.left)) + ' left of ' + esc(money(o.limit)) + '. About ' + esc(money(sum.pace.perDay)) +
            ' a day for the remaining ' + plural(sum.pace.daysLeft, 'day', 'days') + '.</p>'
        );
      } else {
        notes.push('<p>' + esc(money(o.left)) + ' left of ' + esc(money(o.limit)) + '.</p>');
      }
      notes.push('<p class="legend"><span class="legend-dash" aria-hidden="true"></span>Daily budget ' + esc(money(sum.dailyAllowance)) + '</p>');
    } else if (sum.elapsedDays > 0 && sum.expense > 0) {
      notes.push('<p>Average ' + esc(money(Math.round(sum.expense / sum.elapsedDays))) + ' a day.</p>');
    }

    out.push(
      '<section class="hero" aria-label="' + esc(monthName) + ' summary">' +
        '<p class="hero-label">' + (isCurrent ? 'Spent this month' : 'Spent in ' + esc(monthName)) + '</p>' +
        '<p class="hero-amount num">' + esc(money(sum.expense)) + '</p>' +
        renderStrip(sum, today) +
        '<div class="hero-notes">' + notes.join('') + '</div>' +
        '<dl class="totals">' +
        '<div><dt>Income</dt><dd class="num in">' + esc(money(sum.income)) + '</dd></div>' +
        '<div><dt>Net</dt><dd class="num' + (sum.net < 0 ? ' neg' : '') + '">' + esc(signedMoney(sum.net)) + '</dd></div>' +
        '</dl></section>'
    );

    if (!sum.count) {
      out.push(
        '<p class="empty">' +
          (isPast
            ? 'Nothing was logged in ' + esc(monthName) + '.'
            : 'Nothing logged in ' + esc(monthName) + ' yet. Tap + to add your first expense.') +
          '</p>'
      );
      $('#view-home').innerHTML = out.join('');
      return;
    }

    out.push(
      '<section class="section"><div class="section-head"><h2 class="section-title">Latest entries</h2>' +
        '<button type="button" class="btn small quiet" data-action="nav" data-view="history">See all</button></div>' +
        '<ul class="entries">' + C.recent(state.transactions, state.month, RECENT_COUNT).map((t) => entryRow(t, true)).join('') + '</ul>' +
        '</section>'
    );

    if (sum.budgetRows.length) {
      out.push('<section class="section"><h2 class="section-title">Budgets</h2>' + sum.budgetRows.map(budgetRow).join('') + '</section>');
    } else if (!sum.overall) {
      out.push(
        '<section class="section prompt"><p>Set monthly limits to see how your spending is pacing.</p>' +
          '<button type="button" class="btn small" data-action="nav" data-view="budgets">Set budgets</button></section>'
      );
    }

    if (sum.categoryRows.length) {
      out.push(
        '<section class="section"><h2 class="section-title">Where it went</h2>' +
          sum.categoryRows
            .map((r) => {
              const pct = Math.round(r.share * 100);
              return (
                '<div class="row"><span class="row-name">' + esc(r.name) + ' <span class="share">' + pct + '%</span></span>' +
                '<span class="row-amt num">' + esc(money(r.amount)) + '</span>' +
                '<span class="meter" aria-hidden="true"><span style="width:' + Math.max(pct, 1) + '%"></span></span></div>'
              );
            })
            .join('') +
          '</section>'
      );
    }

    if (sum.expense > 0) {
      const split = C.METHODS.filter((m) => sum.byMethod[m] > 0)
        .map((m) => '<span class="m-' + m + '" style="width:' + ((sum.byMethod[m] / sum.expense) * 100).toFixed(2) + '%"></span>')
        .join('');
      const rows = C.METHODS.map(
        (m) =>
          '<div class="row compact"><span class="row-name"><span class="swatch m-' + m + '" aria-hidden="true"></span>' +
          esc(C.METHOD_LABELS[m]) + ' <span class="share">' + Math.round((sum.byMethod[m] / sum.expense) * 100) + '%</span></span>' +
          '<span class="row-amt num">' + esc(money(sum.byMethod[m])) + '</span></div>'
      ).join('');
      out.push('<section class="section"><h2 class="section-title">Paid with</h2><div class="split" aria-hidden="true">' + split + '</div>' + rows + '</section>');
    }

    $('#view-home').innerHTML = out.join('');
  }

  // One bar per day of the month; the dashed line is the average daily budget.
  function renderStrip(sum, today) {
    const thisMonth = C.monthOf(today);
    const todayDay = state.month === thisMonth ? Number(today.slice(8, 10)) : 0;
    const futureMonth = state.month > thisMonth;
    const scaleMax = Math.max(1, sum.dailyAllowance, Math.max.apply(null, sum.daily));
    let topDay = 0;
    sum.daily.forEach((v, i) => {
      if (v > sum.daily[topDay]) topDay = i;
    });

    const bars = sum.daily
      .map((v, i) => {
        const day = i + 1;
        const cls = ['bar'];
        if (day === todayDay) cls.push('today');
        if (futureMonth || (todayDay && day > todayDay)) cls.push('future');
        else if (sum.dailyAllowance && v > sum.dailyAllowance) cls.push('high');
        const h = v > 0 ? Math.max(4, Math.round((v / scaleMax) * 100)) : 0;
        return '<span class="' + cls.join(' ') + '" style="--h:' + h + '%"></span>';
      })
      .join('');
    const pace = sum.dailyAllowance ? '<span class="pace" style="--y:' + Math.round((sum.dailyAllowance / scaleMax) * 100) + '%"></span>' : '';
    const monthName = C.monthLabel(state.month);
    const label = sum.expense
      ? 'Daily spending in ' + monthName + '. Highest day: ' + (topDay + 1) + ', ' + money(sum.daily[topDay]) + '.'
      : 'No spending recorded in ' + monthName + '.';
    const showFirst = !todayDay || todayDay > 3;
    const showLast = !todayDay || todayDay < sum.days - 2;
    const mark = todayDay ? '<span class="today-mark" style="--x:' + (((todayDay - 0.5) / sum.days) * 100).toFixed(2) + '%">Today</span>' : '';

    return (
      '<figure class="strip" role="img" aria-label="' + esc(label) + '">' +
      '<div class="bars">' + bars + pace + '</div>' +
      '<div class="strip-axis"><span>' + (showFirst ? '1' : '') + '</span>' + mark + '<span>' + (showLast ? sum.days : '') + '</span></div>' +
      '</figure>'
    );
  }

  function budgetRow(b) {
    const pct = Math.min(100, Math.round(b.ratio * 100));
    const sub = b.left >= 0 ? money(b.left) + ' left' : money(-b.left) + ' over';
    return (
      '<div class="row">' +
      '<span class="row-name">' + esc(b.name) + '</span>' +
      '<span class="row-amt num">' + esc(money(b.spent)) + '<span class="of"> of ' + esc(money(b.limit)) + '</span></span>' +
      '<span class="meter ' + b.status + '" aria-hidden="true"><span style="width:' + pct + '%"></span></span>' +
      '<span class="row-sub ' + b.status + '">' + esc(sub) + '</span>' +
      '</div>'
    );
  }

  function entryRow(t, withDate) {
    const meta = [];
    if (withDate) meta.push(C.dayLabel(t.date, C.todayISO()));
    meta.push(C.METHOD_LABELS[t.method] || t.method);
    return (
      '<li><button type="button" class="entry" data-action="edit" data-id="' + esc(t.id) + '">' +
      '<span class="entry-main"><span class="entry-cat">' + esc(catName(t.categoryId)) + '</span>' +
      (t.note ? '<span class="entry-note">' + esc(t.note) + '</span>' : '') +
      '</span>' +
      '<span class="entry-amt num ' + t.type + '">' + (t.type === 'income' ? '+' : '') + esc(money(t.amount)) + '</span>' +
      '<span class="entry-meta">' + esc(meta.join(', ')) + '</span>' +
      '</button></li>'
    );
  }

  function renderHistory() {
    const catSelect = $('#f-category');
    const group = (type, label) => {
      const cats = state.categories.filter((c) => c.type === type);
      if (!cats.length) return '';
      return (
        '<optgroup label="' + label + '">' +
        cats.map((c) => '<option value="' + esc(c.id) + '">' + esc(c.name) + (c.archived ? ' (hidden)' : '') + '</option>').join('') +
        '</optgroup>'
      );
    };
    catSelect.innerHTML = '<option value="all">All categories</option>' + group('expense', 'Expenses') + group('income', 'Income');
    if (state.filters.category !== 'all' && !catById(state.filters.category)) state.filters.category = 'all';
    $('#f-type').value = state.filters.type;
    $('#f-method').value = state.filters.method;
    catSelect.value = state.filters.category;

    const list = C.filterTransactions(state.transactions, Object.assign({ month: state.month }, state.filters));
    const groups = C.groupByDate(list);
    const filtered = state.filters.type !== 'all' || state.filters.method !== 'all' || state.filters.category !== 'all';
    const monthName = C.monthLabel(state.month);
    const meta = $('#history-meta');
    const listEl = $('#history-list');

    if (!groups.length) {
      meta.textContent = '';
      listEl.innerHTML =
        '<p class="empty">' + (filtered ? 'No entries in ' + esc(monthName) + ' match these filters.' : 'No entries in ' + esc(monthName) + '.') + '</p>';
      return;
    }

    let spent = 0;
    let received = 0;
    list.forEach((t) => {
      if (t.type === 'income') received += t.amount;
      else spent += t.amount;
    });
    const bits = [plural(list.length, 'entry', 'entries')];
    if (spent) bits.push(money(spent) + ' spent');
    if (received) bits.push(money(received) + ' received');
    meta.textContent = bits.join(', ');

    const today = C.todayISO();
    listEl.innerHTML = groups
      .map((g) => {
        const totals = [];
        if (g.expense) totals.push(esc(money(g.expense)));
        if (g.income) totals.push('<span class="in">+' + esc(money(g.income)) + '</span>');
        return (
          '<section class="day"><header class="day-head"><h3>' + esc(C.dayLabel(g.date, today)) + '</h3>' +
          '<span class="num">' + totals.join(' ') + '</span></header>' +
          '<ul class="entries">' + g.items.map((t) => entryRow(t, false)).join('') + '</ul></section>'
        );
      })
      .join('');
  }

  function renderBudgets() {
    const cats = state.categories.filter((c) => c.type === 'expense' && !c.archived);
    $('#view-budgets').innerHTML =
      '<form id="budget-form" class="budget-form" novalidate>' +
      '<p class="lede">Limits repeat every month. Leave a field empty for no limit.</p>' +
      '<div class="ledger">' +
      '<label class="ledger-row total-row"><span>All spending</span>' +
      '<input name="overall" inputmode="decimal" placeholder="No limit" value="' + esc(C.minorToInput(state.settings.overallBudget)) + '"></label>' +
      '</div>' +
      '<h2 class="section-title">By category</h2>' +
      '<div class="ledger">' +
      cats
        .map(
          (c) =>
            '<label class="ledger-row"><span>' + esc(c.name) + '</span>' +
            '<input data-cat="' + esc(c.id) + '" inputmode="decimal" placeholder="No limit" value="' + esc(C.minorToInput(c.budget)) + '"></label>'
        )
        .join('') +
      '</div>' +
      '<p class="hint" id="budget-sum" aria-live="polite"></p>' +
      '<p class="form-error" id="budget-error" role="alert" hidden></p>' +
      '<button type="submit" class="btn primary block">Save budgets</button>' +
      '</form>';
    updateBudgetHint();
  }

  function updateBudgetHint() {
    const form = $('#budget-form');
    const hint = $('#budget-sum');
    if (!form || !hint) return;
    let total = 0;
    $$('input[data-cat]', form).forEach((input) => {
      const v = C.readAmount(input.value, state.settings.currency).value;
      if (Number.isFinite(v)) total += v;
    });
    const overall = C.readAmount(form.elements.overall.value, state.settings.currency).value;
    if (!total) {
      hint.textContent = '';
    } else if (Number.isFinite(overall) && overall > 0 && total > overall) {
      hint.textContent = 'Category limits add up to ' + money(total) + ', more than your overall limit of ' + money(overall) + '.';
    } else {
      hint.textContent = 'Category limits add up to ' + money(total) + '.';
    }
  }

  function renderSettings() {
    const s = state.settings;
    const install = isStandalone()
      ? ''
      : '<section class="block"><h2 class="section-title">Install on your phone</h2>' +
        '<p>iPhone: open this page in Safari, tap Share, then Add to Home Screen.</p>' +
        '<p>Android: open the Chrome menu and tap Install app.</p>' +
        '<p class="caution">Log from the installed app. On iPhone it keeps its data separate from Safari.</p>' +
        '<div class="btn-row" id="install-action"></div></section>';

    $('#view-settings').innerHTML =
      install +
      '<section class="block"><h2 class="section-title">Backup</h2>' +
      '<p>Your entries are stored only on this device. If the phone is lost or the app’s data is cleared, they’re gone, so save a backup somewhere else every week or so.</p>' +
      '<p class="muted">Last backup: ' + (s.lastBackupAt ? esc(C.relativeDays(s.lastBackupAt, Date.now())) : 'never') + '</p>' +
      '<div class="btn-row">' +
      '<button type="button" class="btn primary" data-action="backup">Back up now</button>' +
      '<button type="button" class="btn" data-action="restore">Restore a backup</button>' +
      '</div>' +
      '<div class="btn-row"><button type="button" class="btn quiet" data-action="export-csv">Export CSV for spreadsheets</button></div>' +
      '</section>' +
      '<section class="block"><h2 class="section-title">Currency</h2>' +
      '<label class="field"><span class="visually-hidden">Currency</span><select id="currency-select">' + currencyOptions(s.currency) + '</select></label>' +
      '<p class="hint">Changing it only changes the symbol. Amounts aren’t converted.</p></section>' +
      categoryBlock('expense', 'Expense categories', false) +
      categoryBlock('income', 'Income categories', true) +
      '<section class="block"><h2 class="section-title">Storage</h2>' +
      '<p id="storage-text">' + esc(storageText()) + '</p>' +
      '<p class="muted">' + plural(state.transactions.length, 'entry', 'entries') + ' saved on this device.</p></section>' +
      '<p class="version">Daily Expenses ' + APP_VERSION + '</p>';
    updateInstallAction();
  }

  function categoryBlock(type, title, withHint) {
    const cats = state.categories.filter((c) => c.type === type);
    return (
      '<section class="block"><h2 class="section-title">' + title + '</h2>' +
      '<ul class="cat-list">' +
      cats
        .map(
          (c) =>
            '<li' + (c.archived ? ' class="archived"' : '') + '>' +
            '<input class="cat-name" data-id="' + esc(c.id) + '" value="' + esc(c.name) + '" maxlength="' + C.NAME_MAX + '" aria-label="Rename ' + esc(c.name) + '">' +
            '<button type="button" class="btn small quiet" data-action="toggle-archive" data-id="' + esc(c.id) + '">' + (c.archived ? 'Show' : 'Hide') + '</button>' +
            '</li>'
        )
        .join('') +
      '</ul>' +
      '<form class="add-cat" data-type="' + type + '" novalidate>' +
      '<input name="name" maxlength="' + C.NAME_MAX + '" placeholder="New category" aria-label="New ' + type + ' category">' +
      '<button type="submit" class="btn">Add</button></form>' +
      (withHint ? '<p class="hint">Hidden categories stay on past entries but aren’t offered for new ones.</p>' : '') +
      '</section>'
    );
  }

  function currencyOptions(selected) {
    if (!currencyItems) {
      let codes = [];
      try {
        if (typeof Intl.supportedValuesOf === 'function') codes = Intl.supportedValuesOf('currency').slice();
      } catch (e) {
        codes = [];
      }
      if (!codes.length) codes = C.FALLBACK_CURRENCIES.slice();
      let names = null;
      try {
        names = new Intl.DisplayNames(undefined, { type: 'currency' });
      } catch (e) {
        names = null;
      }
      currencyItems = codes
        .map((code) => {
          let name = code;
          try {
            if (names) name = names.of(code) || code;
          } catch (e) {
            name = code;
          }
          return { code: code, label: name === code ? code : name + ' (' + code + ')' };
        })
        .sort((a, b) => a.label.localeCompare(b.label));
    }
    const items = currencyItems.some((i) => i.code === selected) ? currencyItems : currencyItems.concat({ code: selected, label: selected });
    return items
      .map((i) => '<option value="' + esc(i.code) + '"' + (i.code === selected ? ' selected' : '') + '>' + esc(i.label) + '</option>')
      .join('');
  }

  function storageText() {
    switch (state.storageStatus) {
      case 'persistent':
        return 'Protected: the browser won’t clear this data to free up space.';
      case 'best-effort':
        return 'Not protected yet: the browser may clear this data if the device runs low on space. Installing the app helps, and backups cover you either way.';
      case 'checking':
        return 'Checking storage protection…';
      default:
        return 'This browser doesn’t report storage protection, so back up regularly.';
    }
  }

  function updateStorageText() {
    const el = $('#storage-text');
    if (el) el.textContent = storageText();
  }

  function updateInstallAction() {
    const el = $('#install-action');
    if (el) el.innerHTML = state.installEvent ? '<button type="button" class="btn primary" data-action="install">Install app</button>' : '';
  }

  /* ---------- entry sheet ---------- */

  function openSheet(tx) {
    if (!state.settings) return;
    const form = $('#tx-form');
    const sheet = $('#sheet');
    const backdrop = $('#backdrop');
    state.editingId = tx ? tx.id : null;
    state.sheetToken = {};
    form.reset();
    hideFormError();

    const type = tx ? tx.type : 'expense';
    setChecked(form, 'type', type);
    renderCategoryChips(type, tx ? tx.categoryId : lastCategory(type));
    setChecked(form, 'method', tx ? tx.method : state.settings.lastMethod[type]);
    form.elements.amount.value = tx ? C.minorToInput(tx.amount) : '';
    form.elements.date.value = tx ? tx.date : C.todayISO();
    form.elements.note.value = tx ? tx.note : '';
    $('#amount-prefix').textContent = C.currencySymbol(state.settings.currency);
    $('#tx-delete').hidden = !tx;
    updateSheetLabels(type);

    lastFocus = document.activeElement;
    sheet.hidden = false;
    backdrop.hidden = false;
    void sheet.offsetHeight; // apply the closed position first so the slide-up animates
    sheet.classList.add('open');
    backdrop.classList.add('open');
    document.body.classList.add('sheet-open');
    $('#app').inert = true;
    // Focus synchronously, inside the tap, so iOS opens the keyboard for a new entry.
    if (tx) $('#sheet-title').focus();
    else form.elements.amount.focus();
  }

  function closeSheet() {
    const sheet = $('#sheet');
    const backdrop = $('#backdrop');
    if (sheet.hidden) return;
    sheet.classList.remove('open');
    backdrop.classList.remove('open');
    document.body.classList.remove('sheet-open');
    $('#app').inert = false;
    state.editingId = null;
    state.sheetToken = null;
    const finish = () => {
      if (sheet.classList.contains('open')) return; // reopened in the meantime
      sheet.hidden = true;
      backdrop.hidden = true;
    };
    if (media('(prefers-reduced-motion: reduce)')) finish();
    else setTimeout(finish, 260);
    restoreFocus(lastFocus);
    lastFocus = null;
  }

  // The button that opened the sheet may have been redrawn by render(); find its replacement by id,
  // and fall back to the add button if the entry is gone (deleted).
  function restoreFocus(el) {
    let target = el && document.contains(el) ? el : null;
    if (!target && el && el.dataset && el.dataset.action === 'edit' && el.dataset.id) {
      target = $$('[data-action="edit"]').find((b) => b.dataset.id === el.dataset.id) || $('.add-btn');
    }
    if (target && typeof target.focus === 'function') target.focus();
  }

  // Shows an error on the sheet if it is still the same sheet, otherwise as a toast so it isn't lost.
  function sheetError(token, message) {
    if (token && state.sheetToken === token) formError(message);
    else toast(message);
  }

  function renderCategoryChips(type, selectedId) {
    const cats = state.categories.filter((c) => c.type === type && (!c.archived || c.id === selectedId));
    $('#tx-categories').innerHTML = cats
      .map(
        (c) =>
          '<label class="chip"><input type="radio" name="category" value="' + esc(c.id) + '"' + (c.id === selectedId ? ' checked' : '') + '>' +
          '<span>' + esc(c.name) + '</span></label>'
      )
      .join('');
  }

  function lastCategory(type) {
    const id = state.settings.lastCategory ? state.settings.lastCategory[type] : null;
    const c = id ? catById(id) : null;
    return c && c.type === type && !c.archived ? c.id : null;
  }

  function updateSheetLabels(type) {
    const editing = !!state.editingId;
    const noun = type === 'income' ? 'income' : 'expense';
    $('#sheet-title').textContent = (editing ? 'Edit ' : 'Add ') + noun;
    $('#tx-save').textContent = editing ? 'Save changes' : 'Add ' + noun;
    $('#method-legend').textContent = type === 'income' ? 'Received in' : 'Paid with';
  }

  function onTypeChange(type) {
    renderCategoryChips(type, lastCategory(type));
    setChecked($('#tx-form'), 'method', state.settings.lastMethod[type]);
    updateSheetLabels(type);
    hideFormError();
  }

  function formError(message, focusEl) {
    const el = $('#tx-error');
    el.textContent = message;
    el.hidden = false;
    if (focusEl) focusEl.focus();
  }

  function hideFormError() {
    const el = $('#tx-error');
    el.hidden = true;
    el.textContent = '';
  }

  async function saveTx(form) {
    if (state.saving) return; // a double tap must not create two entries
    const type = checkedValue(form, 'type') === 'income' ? 'income' : 'expense';
    const parsed = C.readAmount(form.elements.amount.value, state.settings.currency);
    const amount = parsed.value;
    const categoryId = checkedValue(form, 'category');
    const method = checkedValue(form, 'method');
    const date = form.elements.date.value;
    const note = cleanText(form.elements.note.value, C.NOTE_MAX);

    if (parsed.error) return formError(parsed.error, form.elements.amount);
    if (!Number.isFinite(amount) || amount <= 0) return formError('Enter an amount greater than zero.', form.elements.amount);
    if (amount > C.MAX_AMOUNT) return formError('That amount is too large.', form.elements.amount);
    const cat = catById(categoryId);
    if (!cat || cat.type !== type) return formError('Choose a category.');
    if (C.METHODS.indexOf(method) === -1) return formError(type === 'income' ? 'Choose where it was received.' : 'Choose how it was paid.');
    if (!C.isValidISODate(date)) return formError('Choose a valid date.', form.elements.date);

    const existing = state.editingId ? state.transactions.find((t) => t.id === state.editingId) : null;
    const now = Date.now();
    const tx = {
      id: existing ? existing.id : C.uid(),
      type: type,
      amount: amount,
      categoryId: categoryId,
      method: method,
      date: date,
      note: note,
      createdAt: existing ? existing.createdAt : now,
      updatedAt: now
    };
    const lastCat = Object.assign({}, state.settings.lastCategory);
    lastCat[type] = categoryId;
    const lastMethod = Object.assign({}, state.settings.lastMethod);
    lastMethod[type] = method;
    const settings = Object.assign({}, state.settings, { lastMethod: lastMethod, lastCategory: lastCat, lastChangeAt: now });

    const button = $('#tx-save');
    const token = state.sheetToken;
    state.saving = true;
    button.disabled = true;
    try {
      await S.commit({ put: [tx], kv: { settings: settings } });
    } catch (err) {
      sheetError(token, 'Couldn’t save: ' + errMsg(err));
      return;
    } finally {
      state.saving = false;
      button.disabled = false;
    }

    state.transactions = existing ? state.transactions.map((t) => (t.id === tx.id ? tx : t)) : state.transactions.concat(tx);
    state.settings = settings;
    render();
    if (state.sheetToken === token) closeSheet(); // don't close a sheet the user has since reopened
    const message = existing ? 'Changes saved' : type === 'income' ? 'Income added' : 'Expense added';
    toast(C.monthOf(date) !== state.month ? message + ' to ' + C.monthLabel(C.monthOf(date)) : message);
  }

  async function deleteTx(id) {
    const tx = state.transactions.find((t) => t.id === id);
    if (!tx) return;
    const settings = Object.assign({}, state.settings, { lastChangeAt: Date.now() });
    const token = state.sheetToken;
    try {
      await S.commit({ del: [id], kv: { settings: settings } });
    } catch (err) {
      sheetError(token, 'Couldn’t delete: ' + errMsg(err));
      return;
    }
    state.transactions = state.transactions.filter((t) => t.id !== id);
    state.settings = settings;
    render();
    if (state.sheetToken === token) closeSheet();
    toast('Entry deleted', { label: 'Undo', run: () => undoDelete(tx) });
  }

  async function undoDelete(tx) {
    if (state.transactions.some((t) => t.id === tx.id)) return;
    const settings = Object.assign({}, state.settings, { lastChangeAt: Date.now() });
    try {
      await S.commit({ put: [tx], kv: { settings: settings } });
    } catch (err) {
      toast('Couldn’t restore the entry: ' + errMsg(err));
      return;
    }
    state.transactions = state.transactions.concat(tx);
    state.settings = settings;
    render();
    toast('Entry restored');
  }

  /* ---------- budgets & categories ---------- */

  async function saveBudgets(form) {
    const errEl = $('#budget-error');
    errEl.hidden = true;
    const read = (input, label) => {
      const raw = input.value.trim();
      if (!raw) return 0;
      const parsed = C.readAmount(raw, state.settings.currency);
      const v = parsed.value;
      if (!Number.isFinite(v) || v > C.MAX_AMOUNT) {
        errEl.textContent = label + (parsed.error ? ': ' + parsed.error : ' isn’t a valid amount.');
        errEl.hidden = false;
        input.focus();
        return null;
      }
      return v;
    };
    const overall = read(form.elements.overall, 'The overall limit');
    if (overall === null) return;
    const limits = new Map();
    for (const input of $$('input[data-cat]', form)) {
      const v = read(input, 'The limit for ' + catName(input.dataset.cat));
      if (v === null) return;
      limits.set(input.dataset.cat, v);
    }
    const categories = state.categories.map((c) => (limits.has(c.id) ? Object.assign({}, c, { budget: limits.get(c.id) }) : c));
    const settings = Object.assign({}, state.settings, { overallBudget: overall, lastChangeAt: Date.now() });
    try {
      await S.commit({ kv: { categories: categories, settings: settings } });
    } catch (err) {
      errEl.textContent = 'Couldn’t save: ' + errMsg(err);
      errEl.hidden = false;
      return;
    }
    state.categories = categories;
    state.settings = settings;
    renderBudgets();
    toast('Budgets saved');
  }

  async function saveCategories(categories) {
    const settings = Object.assign({}, state.settings, { lastChangeAt: Date.now() });
    try {
      await S.commit({ kv: { categories: categories, settings: settings } });
    } catch (err) {
      toast('Couldn’t save: ' + errMsg(err));
      return false;
    }
    state.categories = categories;
    state.settings = settings;
    return true;
  }

  async function addCategory(form) {
    const type = form.dataset.type === 'income' ? 'income' : 'expense';
    const input = form.elements.name;
    const name = cleanText(input.value, C.NAME_MAX);
    if (!name) {
      input.focus();
      return;
    }
    if (state.categories.some((c) => c.type === type && c.name.toLowerCase() === name.toLowerCase())) {
      toast(name + ' already exists');
      return;
    }
    const categories = state.categories.concat({ id: C.uid(), name: name, type: type, budget: 0, archived: false });
    if (await saveCategories(categories)) {
      renderSettings();
      toast(name + ' added');
    }
  }

  // Saves on "change" (blur or Enter) and doesn't re-render, so focus stays where the user moved it.
  async function renameCategory(input) {
    const cat = catById(input.dataset.id);
    if (!cat) return;
    const name = cleanText(input.value, C.NAME_MAX);
    if (!name) {
      input.value = cat.name;
      toast('Category names can’t be empty');
      return;
    }
    if (name === cat.name) {
      input.value = name;
      return;
    }
    if (state.categories.some((c) => c.id !== cat.id && c.type === cat.type && c.name.toLowerCase() === name.toLowerCase())) {
      input.value = cat.name;
      toast(name + ' already exists');
      return;
    }
    const categories = state.categories.map((c) => (c.id === cat.id ? Object.assign({}, c, { name: name }) : c));
    if (await saveCategories(categories)) {
      input.value = name;
      toast('Renamed to ' + name);
    } else {
      input.value = cat.name;
    }
  }

  async function toggleArchive(id) {
    const cat = catById(id);
    if (!cat) return;
    if (!cat.archived && state.categories.filter((c) => c.type === cat.type && !c.archived).length <= 1) {
      toast('Keep at least one ' + cat.type + ' category visible');
      return;
    }
    const categories = state.categories.map((c) => (c.id === id ? Object.assign({}, c, { archived: !c.archived }) : c));
    if (await saveCategories(categories)) {
      renderSettings();
      toast(cat.archived ? cat.name + ' is visible again' : cat.name + ' hidden');
    }
  }

  async function changeCurrency(select) {
    const code = select.value;
    if (code === state.settings.currency) return;
    if (state.transactions.length && !window.confirm('Switch to ' + code + '? Amounts you’ve logged keep their numbers. They aren’t converted.')) {
      select.value = state.settings.currency;
      return;
    }
    const settings = Object.assign({}, state.settings, { currency: code, lastChangeAt: Date.now() });
    try {
      await S.commit({ kv: { settings: settings } });
    } catch (err) {
      select.value = state.settings.currency;
      toast('Couldn’t save: ' + errMsg(err));
      return;
    }
    state.settings = settings;
    toast('Currency set to ' + code);
  }

  /* ---------- backup, restore, export ---------- */

  // navigator.share must run inside the tap, so nothing here awaits before it.
  async function shareOrDownload(text, filename, mime) {
    let file = null;
    try {
      file = new File([text], filename, { type: mime });
    } catch (e) {
      file = null;
    }
    if (file && navigator.canShare && navigator.share) {
      let shareable = false;
      try {
        shareable = navigator.canShare({ files: [file] });
      } catch (e) {
        shareable = false;
      }
      if (shareable) {
        try {
          await navigator.share({ files: [file], title: filename });
          return true;
        } catch (err) {
          if (err && err.name === 'AbortError') return false; // share sheet closed
          // Any other failure falls back to a normal download.
        }
      }
    }
    return downloadFile(text, filename, mime);
  }

  function downloadFile(text, filename, mime) {
    try {
      const url = URL.createObjectURL(new Blob([text], { type: mime }));
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 30000);
      return true;
    } catch (err) {
      toast('Couldn’t create the file: ' + errMsg(err));
      return false;
    }
  }

  async function backupNow() {
    const now = Date.now();
    const data = C.buildBackup({ settings: state.settings, categories: state.categories, transactions: state.transactions }, now);
    const saved = await shareOrDownload(JSON.stringify(data, null, 2), 'expenses-backup-' + C.todayISO() + '.json', 'application/json');
    if (!saved) return;
    const settings = Object.assign({}, state.settings, { lastBackupAt: now });
    try {
      await S.commit({ kv: { settings: settings } });
      state.settings = settings;
    } catch (err) {
      /* the file itself is saved; only the reminder timestamp failed */
    }
    state.backupSnoozed = false;
    if (state.view === 'home' || state.view === 'settings') render();
    toast('Backup saved');
  }

  function exportCSV() {
    if (!state.transactions.length) {
      toast('Nothing to export yet');
      return;
    }
    const csv = C.toCSV(state.transactions, state.categories, state.settings.currency);
    shareOrDownload(csv, 'expenses-' + C.todayISO() + '.csv', 'text/csv').then((ok) => {
      if (ok) toast('CSV exported');
    });
  }

  function readFileText(file) {
    if (typeof file.text === 'function') return file.text();
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result));
      reader.onerror = () => reject(reader.error || new Error('Couldn’t read the file'));
      reader.readAsText(file);
    });
  }

  async function restoreFromFile(file) {
    let parsed;
    try {
      parsed = JSON.parse(await readFileText(file));
    } catch (err) {
      toast('That file isn’t a backup from this app.');
      return;
    }
    const result = C.validateBackup(parsed);
    if (!result.ok) {
      toast(result.error);
      return;
    }
    const d = result.data;
    const when = d.exportedAt && !isNaN(Date.parse(d.exportedAt)) ? new Date(d.exportedAt).toLocaleString() : 'an unknown date';
    const confirmed = window.confirm(
      'Replace everything on this device with this backup?\n\n' +
        plural(d.transactions.length, 'entry', 'entries') + ', saved ' + when + '.\n\n' +
        'What’s on this device now will be overwritten.'
    );
    if (!confirmed) return;

    // The restored data matches a file the user already has, so it counts as backed up.
    const settings = Object.assign({}, d.settings, { lastBackupAt: Date.now(), lastChangeAt: 0 });
    try {
      await S.commit({ clear: true, put: d.transactions, kv: { settings: settings, categories: d.categories } });
    } catch (err) {
      toast('Restore failed and nothing was changed: ' + errMsg(err));
      return;
    }
    state.settings = settings;
    state.categories = d.categories;
    state.transactions = d.transactions;
    state.filters = { type: 'all', method: 'all', category: 'all' };
    state.month = C.monthOf(C.todayISO());
    render();
    toast('Restored ' + plural(d.transactions.length, 'entry', 'entries'));
  }

  /* ---------- toast ---------- */

  function toast(message, action) {
    const el = $('#toast');
    const button = $('#toast-action');
    $('#toast-msg').textContent = message;
    if (action) {
      button.textContent = action.label;
      button.hidden = false;
      button.onclick = () => {
        hideToast();
        action.run();
      };
    } else {
      button.hidden = true;
      button.onclick = null;
    }
    el.hidden = false;
    void el.offsetHeight;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(hideToast, action ? 6000 : 2800);
  }

  function hideToast() {
    const el = $('#toast');
    el.classList.remove('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      if (!el.classList.contains('show')) el.hidden = true;
    }, 220);
  }

  /* ---------- install & updates ---------- */

  async function promptInstall() {
    const e = state.installEvent;
    if (!e) return;
    state.installEvent = null;
    try {
      await e.prompt();
      await e.userChoice;
    } catch (err) {
      /* dismissed */
    }
    updateInstallAction();
  }

  function registerServiceWorker() {
    if (!('serviceWorker' in navigator) || !/^https?:$/.test(window.location.protocol)) return;
    navigator.serviceWorker.addEventListener('controllerchange', () => {
      // Reload only when the user asked for the update, never in the middle of an entry.
      if (state.updating) {
        state.updating = false;
        window.location.reload();
      }
    });
    const register = () => {
      navigator.serviceWorker
        .register('./sw.js')
        .then((reg) => {
          state.swReg = reg;
          if (reg.waiting && navigator.serviceWorker.controller) showUpdateBanner();
          reg.addEventListener('updatefound', () => {
            const worker = reg.installing;
            if (!worker) return;
            worker.addEventListener('statechange', () => {
              if (worker.state === 'installed' && navigator.serviceWorker.controller) showUpdateBanner();
            });
          });
        })
        .catch((err) => console.warn('Service worker registration failed:', err));
    };
    if (document.readyState === 'complete') register();
    else window.addEventListener('load', register);
  }

  function showUpdateBanner() {
    $('#update-banner').hidden = false;
  }

  function applyUpdate() {
    const waiting = state.swReg && state.swReg.waiting;
    state.updating = true;
    if (waiting) waiting.postMessage({ type: 'SKIP_WAITING' });
    else window.location.reload();
  }

  /* ---------- events ---------- */

  const ACTIONS = {
    nav: (el) => navTo(el.dataset.view),
    add: () => openSheet(null),
    edit: (el) => {
      const tx = state.transactions.find((t) => t.id === el.dataset.id);
      if (tx) openSheet(tx);
    },
    'close-sheet': () => closeSheet(),
    'delete-tx': () => {
      if (state.editingId) deleteTx(state.editingId);
    },
    'month-prev': () => shiftMonth(-1),
    'month-next': () => shiftMonth(1),
    'month-today': () => {
      state.month = C.monthOf(C.todayISO());
      render();
    },
    backup: () => backupNow(),
    'snooze-backup': () => {
      state.backupSnoozed = true;
      render();
    },
    restore: () => {
      const input = $('#restore-input');
      input.value = '';
      input.click();
    },
    'export-csv': () => exportCSV(),
    'toggle-archive': (el) => toggleArchive(el.dataset.id),
    'finish-setup': (el) => finishSetup(el),
    install: () => promptInstall(),
    'apply-update': () => applyUpdate()
  };

  function navTo(view) {
    if (VIEWS.indexOf(view) === -1) return;
    closeSheet();
    state.view = view;
    render();
    try {
      window.scrollTo(0, 0);
    } catch (e) {
      /* not supported */
    }
  }

  function shiftMonth(delta) {
    state.month = C.addMonths(state.month, delta);
    render();
  }

  function onClick(e) {
    const el = e.target.closest ? e.target.closest('[data-action]') : null;
    if (!el || el.disabled) return;
    const fn = ACTIONS[el.dataset.action];
    if (!fn) return;
    e.preventDefault();
    fn(el, e);
  }

  function onChange(e) {
    const t = e.target;
    if (t.name === 'type' && t.form && t.form.id === 'tx-form') {
      onTypeChange(t.value);
    } else if (t.id === 'f-type' || t.id === 'f-method' || t.id === 'f-category') {
      state.filters = { type: $('#f-type').value, method: $('#f-method').value, category: $('#f-category').value };
      renderHistory();
    } else if (t.id === 'currency-select') {
      changeCurrency(t);
    } else if (t.classList && t.classList.contains('cat-name')) {
      renameCategory(t);
    } else if (t.id === 'restore-input') {
      const file = t.files && t.files[0];
      if (file) restoreFromFile(file);
    }
  }

  function onInput(e) {
    if (e.target.closest && e.target.closest('#budget-form')) updateBudgetHint();
  }

  function onSubmit(e) {
    const form = e.target;
    e.preventDefault();
    if (form.id === 'tx-form') saveTx(form);
    else if (form.id === 'budget-form') saveBudgets(form);
    else if (form.classList.contains('add-cat')) addCategory(form);
  }

  // The app can sit in the background for days: roll "today" (and the month) forward on return.
  function onVisible() {
    if (document.visibilityState !== 'visible' || !state.settings) return;
    const today = C.todayISO();
    if (today !== state.lastToday) {
      if (state.month === C.monthOf(state.lastToday)) state.month = C.monthOf(today);
      state.lastToday = today;
    }
    // Another tab (or a frozen background tab's missed message) may have changed the data meanwhile.
    reloadFromStore();
    if (state.swReg) state.swReg.update().catch(() => {});
  }

  // Re-reads everything from IndexedDB, so this tab never writes stale settings or categories over
  // changes made in another tab.
  async function reloadFromStore() {
    let data;
    try {
      data = await S.loadAll();
    } catch (err) {
      return;
    }
    if (!data.settings) return;
    state.transactions = Array.isArray(data.transactions) ? data.transactions : [];
    if (Array.isArray(data.categories) && data.categories.length) state.categories = data.categories;
    const firstLoad = !state.settings;
    state.settings = C.normalizeSettings(data.settings);
    if (firstLoad || $('#app').hidden) {
      start(); // setup was finished in another tab
      return;
    }
    refreshView();
  }

  // Redraws the current view, but leaves Budgets and Settings alone while the user is typing in them.
  function refreshView() {
    const view = $('#view-' + state.view);
    const active = document.activeElement;
    const typing = active && view && view.contains(active) && /^(INPUT|SELECT|TEXTAREA)$/.test(active.tagName);
    if (state.view === 'home' || state.view === 'history' || !typing) render();
  }

  function bindEvents() {
    document.addEventListener('click', onClick);
    document.addEventListener('change', onChange);
    document.addEventListener('input', onInput);
    document.addEventListener('submit', onSubmit);
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') closeSheet();
    });
    document.addEventListener('visibilitychange', onVisible);
    if (S.onExternalChange) S.onExternalChange(reloadFromStore);
    window.addEventListener('beforeinstallprompt', (e) => {
      e.preventDefault();
      state.installEvent = e;
      updateInstallAction();
    });
    window.addEventListener('appinstalled', () => {
      state.installEvent = null;
      updateInstallAction();
    });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
