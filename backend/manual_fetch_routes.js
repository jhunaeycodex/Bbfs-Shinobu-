const axios = require('axios');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const {
  normalizeMarketCode,
  resolveAliasByCanonical,
  saveCanonicalResult,
  titleCase
} = require('./market_alias');

const RUNTIME_DIR = '/opt/bbfs-shinobi/runtime';
const STATUS_FILE = path.join(RUNTIME_DIR, 'manual_fetch_all_status.json');
const LOG_FILE = path.join(RUNTIME_DIR, 'manual_fetch_all.log');

const MONTHS = {
  jan:'01', januari:'01', january:'01', feb:'02', februari:'02', february:'02', mar:'03', maret:'03', march:'03',
  apr:'04', april:'04', mei:'05', may:'05', jun:'06', juni:'06', june:'06', jul:'07', juli:'07', july:'07',
  agu:'08', ags:'08', agustus:'08', august:'08', sep:'09', september:'09', okt:'10', oktober:'10', oct:'10', october:'10',
  nov:'11', november:'11', des:'12', desember:'12', dec:'12', december:'12'
};

function checkToken(req) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  return process.env.ADMIN_API_TOKEN && token === process.env.ADMIN_API_TOKEN;
}

function assertAllowedUrl(rawUrl) {
  const u = new URL(String(rawUrl || '').trim());
  if (u.protocol !== 'https:') throw new Error('URL harus https.');
  if (!/^prediksi\d+\.angka-alexis\.pro$/i.test(u.hostname)) throw new Error('Domain sumber tidak diizinkan. Pakai prediksiXX.angka-alexis.pro.');
  return u.toString();
}

function slugify(value) {
  return String(value || '').trim().toLowerCase().replace(/&/g,'and').replace(/\+/g,'plus').replace(/[^a-z0-9:]+/g,'-').replace(/^-+|-+$/g,'').slice(0,120);
}
function parseDate(value) {
  let raw = String(value || '').trim().toLowerCase();
  raw = raw.replace(/senin|selasa|rabu|kamis|jumat|jum'at|sabtu|minggu|monday|tuesday|wednesday|thursday|friday|saturday|sunday/g,'').replace(/,/g,' ').replace(/\s+/g,' ').trim();
  let m = raw.match(/(\d{4})[-/](\d{1,2})[-/](\d{1,2})/); if (m) return `${m[1]}-${m[2].padStart(2,'0')}-${m[3].padStart(2,'0')}`;
  m = raw.match(/(\d{1,2})[-/](\d{1,2})[-/](\d{4})/); if (m) return `${m[3]}-${m[2].padStart(2,'0')}-${m[1].padStart(2,'0')}`;
  m = raw.match(/(\d{1,2})[-\s]+([a-z]+)[-\s]+(\d{4})/); if (m && MONTHS[m[2]]) return `${m[3]}-${MONTHS[m[2]]}-${m[1].padStart(2,'0')}`;
  return null;
}
function cleanResult(value) { const raw = String(value || '').trim(); if (/^\d{1,2}:\d{2}/.test(raw)) return null; const digits = raw.replace(/\D/g,''); return /^[0-9]{2,7}$/.test(digits) ? digits : null; }
function ownText($, el) { const clone = $(el).clone(); clone.children().remove(); return clone.text().replace(/\s+/g,' ').trim(); }
function detectMarketName($, fallbackMarket) { let name=''; $('body *').each((_,el)=>{ if(name)return; const m=ownText($,el).match(/RESULT\s+LENGKAP\s+([A-Z0-9:\-\s]+)/i); if(m) name=m[1].replace(/\s+/g,' ').trim(); }); return name || fallbackMarket || 'manual-source'; }
function extractRows(html, marketContext) {
  const $ = cheerio.load(String(html || ''));
  const marketName = detectMarketName($, marketContext?.source_name || marketContext?.canonical_market_name || 'manual-source');
  const marketCode = marketContext?.canonical_market_code || slugify(marketName);
  const rows = [];
  $('table tr').each((_,tr)=>{
    const cells = $(tr).find('td,th').map((__,td)=>$(td).text().replace(/\s+/g,' ').trim()).get();
    if (cells.length < 3) return;
    if (/hari\s+tanggal\s+prize/i.test(cells.join(' '))) return;
    let drawDate=null, result=null, resultTime=null;
    for (const cell of cells) if(!drawDate) drawDate=parseDate(cell);
    for (const cell of cells) { const r=cleanResult(cell); if(r && !parseDate(cell)) { result=r; break; } }
    for (const cell of cells) if(/^\d{1,2}:\d{2}/.test(cell)) { resultTime=cell; break; }
    if(drawDate && result) rows.push({
      canonical_market_id: marketContext?.canonical_market_id || null,
      canonical_market_code: marketContext?.canonical_market_code || marketCode,
      canonical_market_name: marketContext?.canonical_market_name || titleCase(marketName),
      source_name: marketContext?.source_name || titleCase(marketName),
      source_value: marketContext?.source_value || marketCode,
      source_code: marketContext?.source_code || slugify(marketContext?.source_value || marketCode),
      draw_date: drawDate,
      result,
      result_time: resultTime,
      raw: { cells }
    });
  });
  const unique = new Map(); for (const row of rows) unique.set(`${row.canonical_market_code}|${row.draw_date}|${row.result}`, row); return [...unique.values()];
}
async function fetchDirect(url) {
  const response = await axios.get(url,{timeout:60000,maxContentLength:Infinity,maxBodyLength:Infinity,headers:{'User-Agent':'Mozilla/5.0 BBFS-Shinobi-Manual/1.0','Accept':'text/html,*/*'}});
  return String(response.data || '');
}
async function fetchWithBrowser(url, marketContext) {
  const { chromium } = require('playwright');
  const browser = await chromium.launch({headless:true,args:['--no-sandbox','--disable-dev-shm-usage']});
  try {
    const page = await browser.newPage({timezoneId:'Asia/Jakarta',userAgent:'Mozilla/5.0 BBFS-Shinobi-Manual/1.0'});
    await page.route('**/*', route => { const t=route.request().resourceType(); if(['image','font','media'].includes(t)) return route.abort(); return route.continue(); });
    await page.goto(url,{waitUntil:'domcontentloaded',timeout:60000});
    await page.waitForTimeout(2500);
    if (marketContext) {
      await page.evaluate(({market})=>{
        const wanted=String(market?.source_value || market?.source_name || market || '').trim().toLowerCase(); const compact=wanted.replace(/[^a-z0-9]+/g,'');
        function fire(el){el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true}));}
        for(const select of Array.from(document.querySelectorAll('select'))){
          const opt=Array.from(select.options||[]).find(o=>{const val=String(o.value||'').toLowerCase(); const txt=String(o.textContent||'').trim().toLowerCase(); const c1=val.replace(/[^a-z0-9]+/g,''); const c2=txt.replace(/[^a-z0-9]+/g,''); return val===wanted || txt===wanted || c1===compact || c2===compact || txt.includes(wanted);});
          if(opt){select.value=opt.value; fire(select); return true;}
        }
        return false;
      },{market: marketContext});
      await page.waitForTimeout(5000);
      await page.waitForLoadState('networkidle',{timeout:10000}).catch(()=>{});
    }
    return await page.content();
  } finally { await browser.close(); }
}
async function saveRows(pool, rows, sourceUrl, sourceName='manual-fetch-link') {
  const client = await pool.connect(); let inserted=0, updated=0, unchanged=0, conflicts=0;
  try { for (const row of rows) {
    const saved = await saveCanonicalResult(client, {
      sourceUrl,
      source_tag: sourceName,
      canonical_market_id: row.canonical_market_id,
      canonical_market_code: row.canonical_market_code,
      canonical_market_name: row.canonical_market_name,
      source_name: row.source_name,
      source_value: row.source_value,
      source_code: row.source_code,
      draw_date: row.draw_date,
      result: row.result,
      raw: { result_time: row.result_time, raw: row.raw }
    });
    inserted += saved.inserted;
    updated += saved.updated;
    unchanged += saved.unchanged;
    conflicts += saved.conflicts;
  }} finally { client.release(); }
  return {inserted,updated,unchanged,conflicts};
}
function readStatus() { try { return JSON.parse(fs.readFileSync(STATUS_FILE,'utf8')); } catch(e) { return { running:false, message:'Belum ada proses fetch semua.' }; } }

module.exports = function registerManualFetchRoutes(app, pool) {
  app.post('/api/manual/fetch-link', async (req,res)=>{
    try {
      if(!checkToken(req)) return res.status(401).json({ok:false,error:'Unauthorized. Token admin salah.'});
      const sourceUrl = assertAllowedUrl(req.body.url);
      const market = String(req.body.market || '').trim();
      const mode = req.body.mode === 'browser' || market ? 'browser' : 'direct';
      const alias = market ? await resolveAliasByCanonical(pool, sourceUrl, market) : null;
      const marketContext = alias || null;

      if (market && !alias) {
        return res.status(404).json({ ok: false, error: 'Canonical market belum punya alias aktif untuk source ini.' });
      }

      const html = mode === 'browser' ? await fetchWithBrowser(sourceUrl, marketContext) : await fetchDirect(sourceUrl);
      const rows = extractRows(html, marketContext || { canonical_market_code: market, canonical_market_name: titleCase(market), source_name: titleCase(market), source_value: market, source_code: normalizeMarketCode(market) });
      const saved = rows.length ? await saveRows(pool, rows, sourceUrl, 'manual-fetch-link') : {inserted:0,updated:0,unchanged:0,conflicts:0};
      res.json({ok:true, mode, source_url:sourceUrl, market, alias: alias || null, rows_found:rows.length, ...saved, sample: rows.slice(0,20)});
    } catch(error) { res.status(500).json({ok:false,error:error.message}); }
  });

  app.post('/api/manual/fetch-all-start', async (req,res)=>{
    try {
      if(!checkToken(req)) return res.status(401).json({ok:false,error:'Unauthorized. Token admin salah.'});
      const sourceUrl = assertAllowedUrl(req.body.url);
      const current = readStatus();
      if(current.running) return res.json({ok:true, already_running:true, status:current});
      fs.mkdirSync(RUNTIME_DIR,{recursive:true});
      const out = fs.openSync(LOG_FILE, 'a');
      const child = spawn(process.execPath, ['scripts/fetch_all_manual_job.js', sourceUrl], {
        cwd: process.cwd(),
        env: process.env,
        detached: true,
        stdio: ['ignore', out, out]
      });
      child.unref();
      res.json({ok:true, started:true, pid:child.pid, source_url:sourceUrl});
    } catch(error) { res.status(500).json({ok:false,error:error.message}); }
  });

  app.post('/api/manual/fetch-all-status', async (req,res)=>{
    try {
      if(!checkToken(req)) return res.status(401).json({ok:false,error:'Unauthorized. Token admin salah.'});
      res.json({ok:true, status:readStatus()});
    } catch(error) { res.status(500).json({ok:false,error:error.message}); }
  });
};
