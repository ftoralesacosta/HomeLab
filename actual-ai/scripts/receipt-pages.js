// receipt-pages.js — one printable "proof of purchase" HTML page per transaction, from the bank data Actual stores.
// Read-only on the budget. Writes static files to /receipts (host: ~/HomeLab/actual-ai/receipts, gitignored),
// served by Nginx Proxy Manager at https://receipts.ftoralesacosta.me behind Authelia (admin only).
//   /receipts/index.html          every transaction, newest first, grouped by month
//   /receipts/t/<transaction id>.html
//   /receipts/files/<transaction id>[-anything].(jpg|jpeg|png|webp|gif|heic|pdf)   receipts: uploaded with the
//                                  page's "Attach receipt" button (nginx WebDAV PUT, see snippets/receipts.conf)
//                                  or dropped here by hand. Pages list them live, no rebuild needed.
// Run by ../receipt-watch.sh (cron, every minute) only when the budget changed; safe to run any time:
//   docker exec actual-ai node /scripts/receipt-pages.js
const api = require('/opt/node_app/node_modules/@actual-app/api');
const fs = require('fs');
const path = require('path');

const OUT = process.env.RECEIPTS_DIR ?? '/receipts';
const US_STATES = new Set('AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY DC PR'.split(' '));

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = (c, cur = 'USD') => (c / 100).toLocaleString('en-US', { style: 'currency', currency: cur });
const parseRaw = (t) => { try { return t.raw_synced_data ? JSON.parse(t.raw_synced_data) : null; } catch { return null; } };
// same rule as daily-fixups.js: Title-case city right before a trailing US state code, else nothing
const location = (desc) => {
  const w = (desc || '').trim().split(/\s+/);
  if (w.length < 3 || !US_STATES.has(w[w.length - 1])) return null;
  const city = [];
  for (let i = w.length - 2; i >= 0 && city.length < 3; i--) { if (/^[A-Z][a-z]+\.?$/.test(w[i])) city.unshift(w[i]); else break; }
  return city.length ? `${city.join(' ')}, ${w[w.length - 1]}` : null;
};
// the part of Notes the user/scripts wrote, minus the bank descriptor and the enrichment suffix
const userNotes = (notes, desc) => {
  let n = notes || '';
  if (desc && n.startsWith(desc)) n = n.slice(desc.length);
  const i = n.indexOf('| ');
  if (i >= 0) n = n.slice(0, i);
  return n.replace(/#actual-ai\b/g, '').trim() || null;
};

const CSS = `
:root{--fg:#1d1d1f;--mut:#6e6e73;--line:#d2d2d7;--bg:#f5f5f7;--acc:#0a7cff}
*{box-sizing:border-box}body{margin:0;font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;color:var(--fg);background:var(--bg)}
a{color:var(--acc);text-decoration:none}a:hover{text-decoration:underline}
.wrap{max-width:760px;margin:24px auto;padding:0 16px}
.card{background:#fff;border:1px solid var(--line);border-radius:12px;padding:28px 32px}
h1{font-size:22px;margin:0 0 4px}.sub{color:var(--mut);margin:0 0 20px}
.amt{font-size:34px;font-weight:600;margin:6px 0 18px}.amt.in{color:#1a7f37}
table.kv{width:100%;border-collapse:collapse}table.kv th{width:34%;text-align:left;color:var(--mut);font-weight:500;vertical-align:top}
table.kv th,table.kv td{padding:7px 0;border-top:1px solid var(--line)}
code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;word-break:break-all}
.files img{max-width:100%;border:1px solid var(--line);border-radius:8px;margin-top:12px}
.note{color:var(--mut);font-size:12.5px;margin-top:22px}
.bar{display:flex;gap:16px;margin-bottom:14px;font-size:14px}
button{font:inherit;border:1px solid var(--line);background:#fff;border-radius:8px;padding:4px 12px;cursor:pointer}
.list h2{font-size:16px;margin:26px 0 6px;color:var(--mut)}
.list table{width:100%;border-collapse:collapse;background:#fff;border:1px solid var(--line);border-radius:10px;overflow:hidden}
.list td{padding:7px 10px;border-top:1px solid var(--line);font-size:14px}.list td.r{text-align:right;white-space:nowrap}
.list td.d{white-space:nowrap;color:var(--mut)}
input#q{width:100%;padding:8px 12px;border:1px solid var(--line);border-radius:8px;font:inherit}
.att{display:flex;flex-direction:column;gap:12px;margin-top:10px}
.att .it{position:relative}.att img{max-width:100%;border:1px solid var(--line);border-radius:8px;display:block}
.att .del{position:absolute;top:8px;right:8px;background:rgba(255,255,255,.92);font-size:13px;padding:2px 10px}
.att .pdf{display:flex;align-items:center;gap:12px}
.up{display:flex;align-items:center;gap:12px;margin-top:14px}
.btn{display:inline-block;border:1px solid var(--acc);color:var(--acc);border-radius:8px;padding:6px 14px;cursor:pointer;font-weight:500}
.btn:hover{background:#eef5ff}#st{color:var(--mut);font-size:14px}#st.err{color:#c00}
@media print{.del{display:none}body{background:#fff}.bar,.noprint{display:none}.card{border:0;padding:0}.wrap{margin:0;max-width:none}}
`;

const CLIENT_JS = String.raw`
const E=s=>s.replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const att=document.getElementById('att'),st=document.getElementById('st'),h=document.getElementById('atth');
const say=(m,e)=>{st.textContent=m;st.className=e?'err':''};
const enc=encodeURIComponent;
function tile(n){const d=document.createElement('div');d.className='it'+(/\.pdf$/i.test(n)?' pdf':'');const u='/files/'+enc(n);
 d.innerHTML=/\.pdf$/i.test(n)?'<a href="'+u+'">📄 '+E(n)+'</a>':'<a href="'+u+'"><img src="'+u+'" alt="'+E(n)+'"></a>';
 const img=d.querySelector('img');if(img)img.onerror=()=>{d.innerHTML='<a href="'+u+'">🖼 '+E(n)+'</a>';addDel(d,n)};
 addDel(d,n);return d}
function addDel(d,n){const b=document.createElement('button');b.className='del';b.textContent='Remove';
 b.onclick=async()=>{if(!confirm('Remove this receipt?'))return;const r=await fetch('/files/'+enc(n),{method:'DELETE'});
 if(r.ok||r.status===204){load();say('Removed.')}else say('Remove failed ('+r.status+'). Reload the page and try again.',1)};d.appendChild(b)}
async function load(){try{const r=await fetch('/files/',{cache:'no-store'});if(!r.ok)return;const l=await r.json();
 const mine=l.filter(x=>x.type==='file'&&x.name.startsWith(TX)).sort((a,b)=>new Date(a.mtime)-new Date(b.mtime));
 att.replaceChildren(...mine.map(x=>tile(x.name)));h.className=mine.length?'':'noprint'}catch(e){}}
function ext(f){const m=(f.name.match(/\.([A-Za-z0-9]+)$/)||[])[1];let e=(m||'').toLowerCase();
 if(!e){e={'image/jpeg':'jpg','image/png':'png','image/heic':'heic','image/heif':'heif','image/webp':'webp','image/gif':'gif','application/pdf':'pdf'}[f.type]||''}
 if(e==='jpeg')e='jpg';return ['jpg','png','webp','gif','heic','heif','pdf'].includes(e)?e:null}
document.getElementById('f').onchange=async(ev)=>{const fs=[...ev.target.files];ev.target.value='';let ok=0;
 for(const [i,f] of fs.entries()){const e=ext(f);if(!e){say(f.name+': only images or PDF',1);continue}
  if(f.size>25*1024*1024){say(f.name+': larger than 25 MB',1);continue}
  say('Uploading '+(fs.length>1?(i+1)+'/'+fs.length+' ':'')+'…');
  const name=TX+'-'+new Date().toISOString().replace(/[-:.TZ]/g,'').slice(0,14)+(fs.length>1?'_'+(i+1):'')+'.'+e;
  try{const r=await fetch('/files/'+name,{method:'PUT',body:f,headers:{'Content-Type':f.type||'application/octet-stream'}});
   if(r.ok&&new URL(r.url).pathname.startsWith('/files/'))ok++;
   else{say(r.redirected?'Login expired: reload the page, log in, then try again.':'Upload failed ('+r.status+').',1);return}}
  catch(err){say('Upload failed: '+err.message,1);return}}
 if(ok){say(ok>1?ok+' receipts attached.':'Receipt attached.');load()}};
load();
`;

const page = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex">
<title>${esc(title)}</title><link rel="stylesheet" href="/style.css"></head><body><div class="wrap">${body}</div></body></html>\n`;

(async () => {
  const dir = '/tmp/receipt-pages'; fs.mkdirSync(dir, { recursive: true });
  const origLog = console.log; console.log = () => {};
  await api.init({ dataDir: dir, serverURL: process.env.ACTUAL_SERVER_URL, password: process.env.ACTUAL_PASSWORD });
  await api.downloadBudget(process.env.ACTUAL_BUDGET_ID);

  const accounts = await api.getAccounts();
  const acct = Object.fromEntries(accounts.map((a) => [a.id, a]));
  const payees = Object.fromEntries((await api.getPayees()).map((p) => [p.id, p]));
  const cats = Object.fromEntries((await api.getCategoryGroups()).flatMap((g) => g.categories.map((c) => [c.id, `${g.name} › ${c.name}`])));
  const txs = [];
  for (const a of accounts) for (const t of await api.getTransactions(a.id, '1970-01-01', '2100-01-01')) txs.push(t);
  await api.shutdown();
  console.log = origLog;

  fs.mkdirSync(path.join(OUT, 't'), { recursive: true });
  fs.mkdirSync(path.join(OUT, 'files'), { recursive: true });
  const files = fs.readdirSync(path.join(OUT, 'files'));
  const filesFor = (id) => files.filter((f) => f.startsWith(id) && /\.(jpe?g|png|webp|gif|heic|pdf)$/i.test(f));

  const rows = [];
  const keep = new Set();
  for (const t of txs) {
    const b = parseRaw(t);
    const a = acct[t.account] || {};
    const p = payees[t.payee] || {};
    const transfer = t.transfer_id ? (acct[payees[t.payee]?.transfer_acct]?.name || 'another account') : null;
    const vendor = transfer ? `Transfer ${t.amount < 0 ? 'to' : 'from'} ${transfer}` : (p.name || b?.payeeName || t.imported_payee || '(no payee)');
    const desc = b?.notes || null;
    const cur = b?.transactionAmount?.currency || 'USD';
    const loc = location(desc);
    const att = filesFor(t.id);
    const subs = Array.isArray(t.subtransactions) && t.subtransactions.length ? t.subtransactions : null;
    const kv = [
      ['Date', esc(t.date) + (b?.postedDate && b.postedDate !== t.date ? ` <span class="sub">(posted ${esc(b.postedDate)})</span>` : '')],
      ['Vendor', esc(vendor)],
      ['Bank description', desc ? `<code>${esc(desc)}</code>` : null],
      ['Location', loc ? esc(loc) : null],
      ['Paid with', esc(a.name || '')],
      ['Category', subs ? 'Split (see below)' : esc(cats[t.category] || (transfer ? '—' : 'Uncategorized'))],
      ['Notes', esc(userNotes(t.notes, desc) || '') || null],
      ['Status', [t.reconciled ? 'Reconciled' : t.cleared ? 'Cleared' : 'Pending', b ? 'from bank feed (SimpleFIN)' : (t.starting_balance_flag ? 'starting balance' : 'manual / imported')].join(' · ')],
      ['Bank reference', b?.transactionId ? `<code>${esc(b.transactionId)}</code>` : null],
      ['Actual transaction ID', `<code>${esc(t.id)}</code>`],
    ].filter(([, v]) => v);
    const split = subs ? `<h3>Split</h3><table class="kv">${subs.map((s) => `<tr><th>${esc(cats[s.category] || 'Uncategorized')}</th><td>${money(s.amount, cur)}${s.notes ? ' — ' + esc(s.notes) : ''}</td></tr>`).join('')}</table>` : '';
    // attachments: rendered now (works without JS / when printing) and refreshed live from /files/ by the script
    const tile = (f) => /\.pdf$/i.test(f)
      ? `<div class="it pdf"><a href="/files/${encodeURIComponent(f)}">📄 ${esc(f)}</a></div>`
      : `<div class="it"><a href="/files/${encodeURIComponent(f)}"><img src="/files/${encodeURIComponent(f)}" alt="${esc(f)}"></a></div>`;
    const attHtml = `<h3 id="atth"${att.length ? '' : ' class="noprint"'}>Receipt</h3><div class="att" id="att">${att.map(tile).join('')}</div>
<div class="up noprint"><label class="btn">📎 Attach receipt<input type="file" id="f" accept="image/*,application/pdf" multiple hidden></label><span id="st"></span></div>
<script>const TX=${JSON.stringify(t.id)};${CLIENT_JS}</script>`;
    const body = `<div class="bar noprint"><a href="/">← All transactions</a><button onclick="print()">Print / Save as PDF</button></div>
<div class="card"><h1>${esc(vendor)}</h1><p class="sub">Transaction record · ${esc(t.date)}</p>
<div class="amt${t.amount > 0 ? ' in' : ''}">${money(t.amount, cur)}</div>
<table class="kv">${kv.map(([k, v]) => `<tr><th>${k}</th><td>${v}</td></tr>`).join('')}</table>${split}${attHtml}</div>`;
    fs.writeFileSync(path.join(OUT, 't', `${t.id}.html`), page(`${vendor} ${t.date} ${money(t.amount, cur)}`, body));
    keep.add(`${t.id}.html`);
    rows.push({ id: t.id, date: t.date, vendor, amount: money(t.amount, cur), acct: a.name || '', cat: subs ? 'Split' : (cats[t.category] || ''), att: att.length > 0 });
  }
  // remove pages of transactions that no longer exist (deleted/merged in Actual)
  for (const f of fs.readdirSync(path.join(OUT, 't'))) if (!keep.has(f)) fs.unlinkSync(path.join(OUT, 't', f));

  rows.sort((x, y) => y.date.localeCompare(x.date));
  const months = new Map();
  for (const r of rows) { const m = r.date.slice(0, 7); if (!months.has(m)) months.set(m, []); months.get(m).push(r); }
  const index = `<h1>Transactions</h1><p class="sub">${rows.length} records · updated ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC</p>
<input id="q" placeholder="Filter (vendor, card, category, amount, date)…" oninput="f(this.value)">
<div class="list">${[...months].map(([m, rs]) => `<h2>${m}</h2><table>${rs.map((r) =>
    `<tr data-s="${esc((r.date + ' ' + r.vendor + ' ' + r.acct + ' ' + r.cat + ' ' + r.amount).toLowerCase())}"><td class="d">${r.date}</td><td><a href="/t/${r.id}.html">${esc(r.vendor)}</a>${r.att ? ' 📎' : ''}<br><span class="sub">${esc(r.acct)}${r.cat ? ' · ' + esc(r.cat) : ''}</span></td><td class="r">${r.amount}</td></tr>`).join('')}</table>`).join('')}</div>
<script>function f(q){q=q.toLowerCase();document.querySelectorAll('tr[data-s]').forEach(r=>r.style.display=r.dataset.s.includes(q)?'':'none')}</script>`;
  fs.writeFileSync(path.join(OUT, 'index.html'), page('Transactions', index));
  fs.writeFileSync(path.join(OUT, 'style.css'), CSS);
  console.log(`receipt-pages: ${rows.length} pages, ${rows.filter((r) => r.att).length} with receipts -> ${OUT}`);
  process.exit(0);
})().catch(async (e) => { console.error('receipt-pages ERROR', e && (e.message || e)); try { await api.shutdown(); } catch {} process.exit(1); });
