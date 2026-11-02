// refund-match.js — pair refunds with the purchase they reverse, so they cancel out in the budget.
//
// Rule: an INFLOW from a payee that has an OUTFLOW of the EXACT same amount (to the cent) from the same
// payee, dated on or up to REFUND_WINDOW_DAYS before it, is a refund of that purchase.
// Action: the refund gets the purchase's category (purchase -X and refund +X in the same category = 0),
// and both get "#refund-pair:<id>" in Notes. Nothing is deleted: both stay in the account, matching the bank.
// If the purchase has no category yet, the pair is logged as "pending" and retried on the next run.
//
// Every decision is appended as one JSON line to /logs/refund-matches.jsonl (with the refund's old
// category and notes, for undo). REFUND_DRY_RUN=true (default) logs only and changes nothing.
//
// Run (inside the actual-ai container, which has @actual-app/api and the ACTUAL_* variables):
//   docker exec actual-ai node /scripts/refund-match.js
const api = require('/opt/node_app/node_modules/@actual-app/api');
const fs = require('fs');

const DRY = (process.env.REFUND_DRY_RUN ?? 'true').toLowerCase() !== 'false';
const WINDOW_DAYS = parseInt(process.env.REFUND_WINDOW_DAYS ?? '120', 10);
const LOG = process.env.REFUND_LOG_FILE ?? '/logs/refund-matches.jsonl';
const TAG = '#refund-pair:';

const log = (entry) => fs.appendFileSync(LOG, JSON.stringify({ ts: new Date().toISOString(), dry_run: DRY, ...entry }) + '\n');
const days = (a, b) => (new Date(a) - new Date(b)) / 86400000;
const money = (cents) => (cents / 100).toFixed(2);

(async () => {
  const dir = '/tmp/refund-match'; fs.mkdirSync(dir, { recursive: true });
  await api.init({ dataDir: dir, serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await api.downloadBudget(process.env.ACTUAL_BUDGET_ID);

  const payees = Object.fromEntries((await api.getPayees()).map(p => [p.id, p.name]));
  const cats = Object.fromEntries((await api.getCategoryGroups()).flatMap(g => g.categories.map(c => [c.id, c.name])));
  const startCat = Object.entries(cats).find(([, n]) => n === 'Starting Balances')?.[0];

  const txs = [];
  for (const a of await api.getAccounts()) {
    if (a.closed || a.offbudget) continue;
    for (const t of await api.getTransactions(a.id, '1970-01-01', '2100-01-01')) {
      if (t.transfer_id || t.is_parent || !t.payee || t.category === startCat) continue;
      txs.push({ ...t, account_name: a.name });
    }
  }
  const paired = (t) => (t.notes || '').includes(TAG);
  const view = (t) => ({ id: t.id, date: t.date, amount: money(t.amount), payee: payees[t.payee] || t.payee,
    imported_payee: t.imported_payee || null, account: t.account_name, category: cats[t.category] || null, notes: t.notes || null });

  const used = new Set();
  let nPaired = 0, nPending = 0;
  const refunds = txs.filter(t => t.amount > 0 && !paired(t)).sort((a, b) => a.date.localeCompare(b.date));
  for (const r of refunds) {
    const candidates = txs.filter(p => p.amount === -r.amount && p.payee === r.payee && !paired(p) && !used.has(p.id)
      && days(r.date, p.date) >= 0 && days(r.date, p.date) <= WINDOW_DAYS)
      .sort((a, b) => b.date.localeCompare(a.date));           // closest purchase before the refund
    if (!candidates.length) continue;
    const p = candidates[0];
    if (!p.category) { nPending++; log({ action: 'pending_purchase_uncategorized', refund: view(r), purchase: view(p) }); continue; }
    used.add(p.id);
    const pairId = r.id.slice(0, 8);
    const note = (n) => `${n ? n + ' ' : ''}${TAG}${pairId}`;
    log({ action: 'paired', pair_id: pairId, new_refund_category: cats[p.category], refund: view(r), purchase: view(p),
      undo: { refund_id: r.id, category: cats[r.category] || null, notes: r.notes || null, purchase_id: p.id, purchase_notes: p.notes || null } });
    nPaired++;
    if (!DRY) {
      await api.updateTransaction(r.id, { category: p.category, notes: note(r.notes) });
      await api.updateTransaction(p.id, { notes: note(p.notes) });
    }
  }
  if (!DRY) await api.sync();
  log({ action: 'run_summary', paired: nPaired, pending: nPending, refunds_checked: refunds.length, window_days: WINDOW_DAYS });
  console.log(`refund-match: ${DRY ? 'DRY RUN, ' : ''}paired ${nPaired}, pending ${nPending}, checked ${refunds.length} inflows. Log: ${LOG}`);
  await api.shutdown();
})().catch(async (e) => {
  try { log({ action: 'error', message: String(e && e.message || e) }); } catch {}
  console.error('refund-match ERROR', e && e.message || e);
  try { await api.shutdown(); } catch {}
  process.exit(1);
});
