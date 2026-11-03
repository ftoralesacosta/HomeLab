// export-actual.js — readable JSON of the Actual budget's structure (no transactions):
// accounts, category groups/categories, payees, rules, schedules. Printed to stdout.
// Used by ~/HomeLab/backup/backup.sh:  docker exec actual-ai node /scripts/export-actual.js > actual-structure.json
const api = require('/opt/node_app/node_modules/@actual-app/api');
const fs = require('fs');
(async () => {
  const dir = '/tmp/export-actual'; fs.mkdirSync(dir, { recursive: true });
  const origLog = console.log; console.log = () => {};             // keep stdout clean for the JSON
  await api.init({ dataDir: dir, serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await api.downloadBudget(process.env.ACTUAL_BUDGET_ID);
  const out = {
    exported: new Date().toISOString(),
    accounts: (await api.getAccounts()).map(a => ({ id: a.id, name: a.name, offbudget: !!a.offbudget, closed: !!a.closed })),
    category_groups: (await api.getCategoryGroups()).map(g => ({ id: g.id, name: g.name, is_income: !!g.is_income, categories: g.categories.map(c => ({ id: c.id, name: c.name })) })),
    payees: (await api.getPayees()).map(p => ({ id: p.id, name: p.name, transfer_acct: p.transfer_acct || null })),
    rules: await api.getRules(),
    schedules: api.getSchedules ? await api.getSchedules().catch(() => []) : [],
  };
  await api.shutdown();
  console.log = origLog;
  process.stdout.write(JSON.stringify(out, null, 1) + '\n');
  process.exit(0);
})().catch(async (e) => { console.error('ERROR', e.message); try { await api.shutdown(); } catch {} process.exit(1); });
