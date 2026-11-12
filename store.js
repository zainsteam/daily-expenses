/*
 * store.js: IndexedDB persistence for Daily Expenses. No dependencies.
 * Two object stores: "transactions" (one record per entry) and "kv" (settings, categories).
 * Every write goes through commit(), which runs as ONE transaction across both stores,
 * so an entry and the settings it touches are saved together or not at all.
 */
(function (root) {
  'use strict';

  const DB_NAME = 'daily-expenses';
  const DB_VERSION = 1;
  const TX = 'transactions';
  const KV = 'kv';
  let dbPromise = null;

  function open() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise(function (resolve, reject) {
      const idb = root.indexedDB;
      if (!idb) {
        reject(new Error('IndexedDB isn’t available'));
        return;
      }
      let req;
      try {
        req = idb.open(DB_NAME, DB_VERSION);
      } catch (err) {
        reject(err);
        return;
      }
      req.onupgradeneeded = function () {
        const db = req.result;
        if (!db.objectStoreNames.contains(TX)) db.createObjectStore(TX, { keyPath: 'id' });
        if (!db.objectStoreNames.contains(KV)) db.createObjectStore(KV, { keyPath: 'key' });
      };
      req.onsuccess = function () {
        const db = req.result;
        // Let a newer version of the app in another tab upgrade the schema.
        db.onversionchange = function () {
          db.close();
          dbPromise = null;
        };
        db.onclose = function () {
          dbPromise = null;
        };
        resolve(db);
      };
      req.onerror = function () {
        reject(req.error || new Error('Couldn’t open the database'));
      };
    });
    dbPromise.catch(function () {
      dbPromise = null;
    });
    return dbPromise;
  }

  function run(mode, work, isRetry) {
    return open()
      .then(function (db) {
        return new Promise(function (resolve, reject) {
          const tx = db.transaction([TX, KV], mode);
          let read = null;
          tx.oncomplete = function () {
            resolve(read ? read() : undefined);
          };
          tx.onabort = function () {
            reject(tx.error || new Error('The browser cancelled the save'));
          };
          try {
            read = work(tx.objectStore(TX), tx.objectStore(KV)) || null;
          } catch (err) {
            try {
              tx.abort();
            } catch (e) {
              /* already finished */
            }
            reject(err);
          }
        });
      })
      .catch(function (err) {
        // A connection closed underneath us (version change, storage cleared) gets one fresh retry.
        if (!isRetry && err && err.name === 'InvalidStateError') {
          dbPromise = null;
          return run(mode, work, true);
        }
        throw err;
      });
  }

  function loadAll() {
    return run('readonly', function (txStore, kvStore) {
      const all = txStore.getAll();
      const settings = kvStore.get('settings');
      const categories = kvStore.get('categories');
      return function () {
        return {
          transactions: all.result || [],
          settings: settings.result ? settings.result.value : null,
          categories: categories.result ? categories.result.value : []
        };
      };
    });
  }

  // Tells other open tabs of the app that the data changed, so they reload before writing over it.
  let channel = null;
  try {
    if (typeof root.BroadcastChannel === 'function') channel = new root.BroadcastChannel(DB_NAME);
  } catch (e) {
    channel = null;
  }

  function onExternalChange(fn) {
    if (channel) channel.onmessage = function () { fn(); };
  }

  function announce() {
    try {
      if (channel) channel.postMessage('changed');
    } catch (e) {
      /* closed channel: nothing to tell */
    }
  }

  // ops: { clear: bool, put: [transaction], del: [id], kv: { key: value } }
  function commit(ops) {
    const o = ops || {};
    return run('readwrite', function (txStore, kvStore) {
      if (o.clear) {
        txStore.clear();
        kvStore.clear();
      }
      (o.put || []).forEach(function (t) {
        txStore.put(t);
      });
      (o.del || []).forEach(function (id) {
        txStore.delete(id);
      });
      Object.keys(o.kv || {}).forEach(function (key) {
        kvStore.put({ key: key, value: o.kv[key] });
      });
    }).then(function (result) {
      announce();
      return result;
    });
  }

  // Asks the browser not to evict this data when the device runs low on space.
  function persist() {
    const sm = root.navigator && root.navigator.storage;
    if (!sm || typeof sm.persist !== 'function') return Promise.resolve('unsupported');
    return Promise.resolve()
      .then(function () {
        return typeof sm.persisted === 'function' ? sm.persisted() : false;
      })
      .then(function (already) {
        return already ? true : sm.persist();
      })
      .then(function (granted) {
        return granted ? 'persistent' : 'best-effort';
      })
      .catch(function () {
        return 'unknown';
      });
  }

  root.Store = { open: open, loadAll: loadAll, commit: commit, persist: persist, onExternalChange: onExternalChange };
})(self);
