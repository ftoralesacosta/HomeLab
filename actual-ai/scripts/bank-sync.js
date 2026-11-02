// bank-sync.js — daily Bank Sync for every linked account, one account at a time (05:45, before actual-ai at 06:00).
// A broken bank connection (e.g. "needs attention") is logged and skipped; the other accounts still sync.
// Each account has a time limit, and the whole run is wrapped in `timeout` by cron, so nothing can hang the morning.
//   docker exec actual-ai node /scripts/bank-sync.js
// Log: /logs/daily-fixups.jsonl (step "bank_sync").
const api = require('/opt/node_app/node_modules/@actual-app/api');
const fs = require('fs');
const LOG = process.env.FIXUPS_LOG_FILE ?? '/logs/daily-fixups.jsonl';
const PER_ACCOUNT_MS = 120000;
const log = (e) => fs.appendFileSync(LOG, JSON.stringify({ ts: new Date().toISOString(), step: 'bank_sync', ...e }) + '\n');
const withTimeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error(`timed out after ${ms / 1000}s`)), ms))]);

(async () => {
  const dir = '/tmp/bank-sync'; fs.mkdirSync(dir, { recursive: true });
  await api.init({ dataDir: dir, serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await api.downloadBudget(process.env.ACTUAL_BUDGET_ID);
  const results = { ok: [], failed: [] };
  for (const a of (await api.getAccounts()).filter(a => !a.closed)) {
    const before = (await api.getTransactions(a.id, '1970-01-01', '2100-01-01')).length;
    try {
      await withTimeout(api.runBankSync({ accountId: a.id }), PER_ACCOUNT_MS);
      const added = (await api.getTransactions(a.id, '1970-01-01', '2100-01-01')).length - before;
      results.ok.push(a.name); log({ action: 'synced', account: a.name, new_transactions: added });
    } catch (e) {
      const msg = String(e && (e.message || e.reason || e.code) || e);
      results.failed.push(`${a.name}: ${msg}`); log({ action: 'failed', account: a.name, error: msg, hint: 'reconnect this bank in SimpleFIN Bridge if it says it needs attention' });
    }
  }
  await api.sync();
  log({ action: 'summary', synced: results.ok.length, failed: results.failed });
  console.log(`bank-sync: ${results.ok.length} synced, ${results.failed.length} failed${results.failed.length ? ' -> ' + results.failed.join(' | ') : ''}`);
  await api.shutdown();
  process.exit(0);
})().catch(async (e) => {
  try { log({ action: 'error', message: String(e && e.message || e) }); } catch {}
  console.error('bank-sync ERROR', e && e.message || e);
  try { await api.shutdown(); } catch {}
  process.exit(1);
});
