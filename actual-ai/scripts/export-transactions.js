// export-transactions.js — readable JSON of EVERY transaction in the budget, with the
// "rich" fields the other scripts ignore: cleared/reconciled, the bank's imported_id and
// imported_payee, the linked schedule/transfer, and the full original bank payload
// (raw_synced_data, saved by SimpleFIN at import time) parsed into an object under "bank".
// Covers all transactions, oldest included. Read-only: changes nothing.
//   docker exec actual-ai node /scripts/export-transactions.js > actual-transactions.json
// Optional range:  docker exec actual-ai node /scripts/export-transactions.js 2026-01-01 2026-12-31
const api = require('/opt/node_app/node_modules/@actual-app/api');
const fs = require('fs');

const START = process.argv[2] || '1970-01-01';
const END = process.argv[3] || '2100-01-01';

const parseRaw = (t) => {
  if (!t.raw_synced_data) return null;
  try { return JSON.parse(t.raw_synced_data); } catch { return { _unparsed: t.raw_synced_data }; }
};

(async () => {
  const dir = '/tmp/export-transactions'; fs.mkdirSync(dir, { recursive: true });
  const origLog = console.log; console.log = () => {};             // keep stdout clean for the JSON
  await api.init({ dataDir: dir, serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await api.downloadBudget(process.env.ACTUAL_BUDGET_ID);

  const accounts = await api.getAccounts();
  const acctName = Object.fromEntries(accounts.map(a => [a.id, a.name]));
  const payees = Object.fromEntries((await api.getPayees()).map(p => [p.id, p.name]));
  const cats = Object.fromEntries((await api.getCategoryGroups()).flatMap(g => g.categories.map(c => [c.id, c.name])));
  const scheds = Object.fromEntries((api.getSchedules ? await api.getSchedules().catch(() => []) : []).map(s => [s.id, s.name]));

  const view = (t) => ({
    id: t.id,
    date: t.date,
    amount: t.amount,                                    // integer cents; see "amount_units" in output
    account: acctName[t.account] || null,
    account_id: t.account,
    payee: payees[t.payee] || null,
    payee_id: t.payee || null,
    category: cats[t.category] || null,
    category_id: t.category || null,
    notes: t.notes || null,
    cleared: !!t.cleared,
    reconciled: !!t.reconciled,
    transfer_id: t.transfer_id || null,
    schedule: t.schedule ? (scheds[t.schedule] || t.schedule) : null,
    imported_id: t.imported_id || null,
    imported_payee: t.imported_payee || null,
    starting_balance_flag: !!t.starting_balance_flag,
    is_parent: !!t.is_parent,
    is_child: !!t.is_child,
    parent_id: t.parent_id || null,
    // where the row came from: bank sync, the auto-created opening balance, or manual/CSV
    source: t.raw_synced_data ? 'bank_sync' : (t.starting_balance_flag ? 'starting_balance' : 'manual_or_import'),
    bank: parseRaw(t),                                   // full SimpleFIN payload, or null
    subtransactions: Array.isArray(t.subtransactions) ? t.subtransactions.map(view) : undefined,
  });

  const transactions = [];
  for (const a of accounts)
    for (const t of await api.getTransactions(a.id, START, END))
      transactions.push(view(t));
  transactions.sort((a, b) => a.date.localeCompare(b.date) || String(a.id).localeCompare(String(b.id)));

  const out = {
    exported: new Date().toISOString(),
    range: { start: START, end: END },
    amount_units: 'integer cents (divide by 100)',
    count: transactions.length,
    transactions,
  };

  await api.shutdown();
  console.log = origLog;
  // exit only after stdout has flushed: a bare process.exit() truncates piped output at 64 KB
  process.stdout.write(JSON.stringify(out, null, 1) + '\n', () => process.exit(0));
})().catch(async (e) => { console.error('ERROR', e && (e.message || e)); try { await api.shutdown(); } catch {} process.exit(1); });
