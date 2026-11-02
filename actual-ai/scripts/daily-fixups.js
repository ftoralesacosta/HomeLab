// daily-fixups.js — deterministic clean-up of the Actual budget, run daily at 06:45 (after actual-ai at 06:00).
// Plain code, no AI. Two steps:
//
// 1. TRANSFER LINKER: a withdrawal whose bank text says it pays one of your own accounts
//    (e.g. "CHASE / CREDIT CRD - AUTOPAY") is linked to the deposit of the EXACT same amount in that account
//    within ±7 days — exactly what Actual's "Make transfer" button does (each side points to the other; the
//    category is cleared when both accounts are on-budget). Ambiguous matches are skipped, never guessed.
// 2. REFUND MATCHER: an inflow from a payee that has an outflow of the EXACT same amount from the same payee,
//    dated on or up to 120 days before it, gets the purchase's category (so both net to 0) and
//    "#refund-pair:<id>" in Notes on both. Nothing is deleted.
//
// Every decision is appended as one JSON line to /logs/daily-fixups.jsonl, with the values needed to undo it.
// FIXUPS_DRY_RUN=true (default) logs only and changes nothing.
//   docker exec actual-ai node /scripts/daily-fixups.js
const api = require('/opt/node_app/node_modules/@actual-app/api');
const fs = require('fs');

const DRY = (process.env.FIXUPS_DRY_RUN ?? process.env.REFUND_DRY_RUN ?? 'true').toLowerCase() !== 'false';
const LOG = process.env.FIXUPS_LOG_FILE ?? '/logs/daily-fixups.jsonl';
const TRANSFER_WINDOW_DAYS = 7;
const REFUND_WINDOW_DAYS = parseInt(process.env.REFUND_WINDOW_DAYS ?? '120', 10);
const REFUND_TAG = '#refund-pair:';

// Bank text (notes or imported payee of the withdrawal) -> which of your accounts receives the money.
// `target` is matched against account names. Edit this list when you add cards/accounts.
const TRANSFER_PATTERNS = [
  { name: 'Chase card payment', text: /CHASE\s*\/\s*CREDIT CRD/i, target: /^(Chase |Amazon Prime Rewards)/ },
  { name: 'Citi card payment', text: /CITI CARD/i, target: /(Costco Anywhere|Citi)/i },
  { name: 'Apple Card payment', text: /APPLECARD/i, target: /^Apple Card/ },
  // "Withdrawal Internet Transfer to / XXXXX9941 CK" -> the account whose name contains 9941
  { name: 'Internal transfer', text: /Transfer to\b.*?(\d{4})\b/i, target: 'digits' },
];

const log = (entry) => fs.appendFileSync(LOG, JSON.stringify({ ts: new Date().toISOString(), dry_run: DRY, ...entry }) + '\n');
const days = (a, b) => (new Date(a) - new Date(b)) / 86400000;
const money = (c) => (c / 100).toFixed(2);

(async () => {
  const dir = '/tmp/daily-fixups'; fs.mkdirSync(dir, { recursive: true });
  await api.init({ dataDir: dir, serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await api.downloadBudget(process.env.ACTUAL_BUDGET_ID);

  const accounts = (await api.getAccounts()).filter(a => !a.closed);
  const acctById = Object.fromEntries(accounts.map(a => [a.id, a]));
  const payeeList = await api.getPayees();
  const payees = Object.fromEntries(payeeList.map(p => [p.id, p.name]));
  const transferPayee = Object.fromEntries(payeeList.filter(p => p.transfer_acct).map(p => [p.transfer_acct, p.id]));
  const cats = Object.fromEntries((await api.getCategoryGroups()).flatMap(g => g.categories.map(c => [c.id, c.name])));
  const startCat = Object.entries(cats).find(([, n]) => n === 'Starting Balances')?.[0];

  const txs = [];
  for (const a of accounts)
    for (const t of await api.getTransactions(a.id, '1970-01-01', '2100-01-01'))
      if (!t.is_parent && t.category !== startCat) txs.push(t);
  const view = (t) => ({ id: t.id, date: t.date, amount: money(t.amount), account: acctById[t.account]?.name, payee: payees[t.payee] || null,
    imported_payee: t.imported_payee || null, notes: t.notes || null, category: cats[t.category] || null });

  // ---------- 1. transfer linker ----------
  const linked = new Set();
  let nLinked = 0, nAmbiguous = 0, nUnmatched = 0;
  const sources = txs.filter(t => t.amount < 0 && !t.transfer_id).sort((a, b) => a.date.localeCompare(b.date));
  for (const s of sources) {
    const text = `${s.notes || ''} ${s.imported_payee || ''}`;
    const pat = TRANSFER_PATTERNS.find(p => p.text.test(text));
    if (!pat) continue;
    let targets;
    if (pat.target === 'digits') { const d = text.match(pat.text)[1]; targets = accounts.filter(a => a.name.includes(d) && a.id !== s.account); }
    else targets = accounts.filter(a => pat.target.test(a.name) && a.id !== s.account);
    const targetIds = new Set(targets.map(a => a.id));
    const cands = txs.filter(t => targetIds.has(t.account) && !t.transfer_id && !linked.has(t.id)
      && t.amount === -s.amount && Math.abs(days(t.date, s.date)) <= TRANSFER_WINDOW_DAYS);
    if (!cands.length) { nUnmatched++; log({ step: 'transfer', action: 'no_counterpart_yet', rule: pat.name, withdrawal: view(s), searched_accounts: targets.map(a => a.name) }); continue; }
    cands.sort((a, b) => Math.abs(days(a.date, s.date)) - Math.abs(days(b.date, s.date)));
    if (cands.length > 1 && Math.abs(days(cands[0].date, s.date)) === Math.abs(days(cands[1].date, s.date))) {
      nAmbiguous++; log({ step: 'transfer', action: 'ambiguous_skipped', rule: pat.name, withdrawal: view(s), candidates: cands.map(view) }); continue;
    }
    const d = cands[0];
    const clearCategory = !!acctById[s.account]?.offbudget === !!acctById[d.account]?.offbudget;
    log({ step: 'transfer', action: 'linked', rule: pat.name, withdrawal: view(s), deposit: view(d), category_cleared: clearCategory,
      undo: { withdrawal: { id: s.id, payee: s.payee, category: s.category ?? null }, deposit: { id: d.id, payee: d.payee, category: d.category ?? null } } });
    linked.add(s.id); linked.add(d.id); nLinked++;
    if (!DRY) {
      await api.internal.send('transactions-batch-update', {
        updated: [
          { id: s.id, ...(clearCategory ? { category: null } : {}), payee: transferPayee[d.account], transfer_id: d.id },
          { id: d.id, ...(clearCategory ? { category: null } : {}), payee: transferPayee[s.account], transfer_id: s.id },
        ],
        runTransfers: false,
      });
    }
  }

  // ---------- 2. refund matcher ----------
  const isPaired = (t) => (t.notes || '').includes(REFUND_TAG);
  const pool = txs.filter(t => !t.transfer_id && !linked.has(t.id) && t.payee && !acctById[t.account]?.offbudget);
  const used = new Set();
  let nPaired = 0, nPending = 0;
  const refunds = pool.filter(t => t.amount > 0 && !isPaired(t)).sort((a, b) => a.date.localeCompare(b.date));
  for (const r of refunds) {
    const cands = pool.filter(p => p.amount === -r.amount && p.payee === r.payee && !isPaired(p) && !used.has(p.id)
      && days(r.date, p.date) >= 0 && days(r.date, p.date) <= REFUND_WINDOW_DAYS).sort((a, b) => b.date.localeCompare(a.date));
    if (!cands.length) continue;
    const p = cands[0];
    if (!p.category) { nPending++; log({ step: 'refund', action: 'pending_purchase_uncategorized', refund: view(r), purchase: view(p) }); continue; }
    used.add(p.id); nPaired++;
    const pairId = r.id.slice(0, 8);
    const note = (n) => `${n ? n + ' ' : ''}${REFUND_TAG}${pairId}`;
    log({ step: 'refund', action: 'paired', pair_id: pairId, new_refund_category: cats[p.category], refund: view(r), purchase: view(p),
      undo: { refund_id: r.id, category: cats[r.category] || null, notes: r.notes || null, purchase_id: p.id, purchase_notes: p.notes || null } });
    if (!DRY) {
      await api.updateTransaction(r.id, { category: p.category, notes: note(r.notes) });
      await api.updateTransaction(p.id, { notes: note(p.notes) });
    }
  }

  if (!DRY) await api.sync();
  const summary = { transfers_linked: nLinked, transfers_ambiguous: nAmbiguous, transfers_waiting: nUnmatched, refunds_paired: nPaired, refunds_pending: nPending };
  log({ step: 'run', action: 'summary', ...summary });
  console.log(`daily-fixups: ${DRY ? 'DRY RUN, ' : ''}${JSON.stringify(summary)} | log: ${LOG}`);
  await api.shutdown();
})().catch(async (e) => {
  try { log({ step: 'run', action: 'error', message: String(e && e.message || e) }); } catch {}
  console.error('daily-fixups ERROR', e && e.message || e);
  try { await api.shutdown(); } catch {}
  process.exit(1);
});
