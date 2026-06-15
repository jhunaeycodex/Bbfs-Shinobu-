require('dotenv').config();

const fs = require('fs');
const path = require('path');
const cheerio = require('cheerio');
const { Pool } = require('pg');
const { chromium } = require('playwright');
const {
  fetchSourceMarketOptions,
  normalizeMarketCode,
  resolveAliasBySourceOption,
  saveCanonicalResult,
  titleCase
} = require('../market_alias');

const sourceUrl = process.argv[2];
const RUNTIME_DIR = '/opt/bbfs-shinobi/runtime';
const STATUS_FILE = path.join(RUNTIME_DIR, 'manual_fetch_all_status.json');
const LOG_FILE = path.join(RUNTIME_DIR, 'manual_fetch_all.log');

const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 5 });

const MONTHS = {
  jan:'01', januari:'01', january:'01', feb:'02', februari:'02', february:'02', mar:'03', maret:'03', march:'03',
  apr:'04', april:'04', mei:'05', may:'05', jun:'06', juni:'06', june:'06', jul:'07', juli:'07', july:'07',
  agu:'08', ags:'08', agustus:'08', august:'08', sep:'09', september:'09', okt:'10', oktober:'10', oct:'10', october:'10',
  nov:'11', november:'11', des:'12', desember:'12', dec:'12', december:'12'
};

let status = {
  running: true,
  started_at: new Date().toISOString(),
  finished_at: null,
  source_url: sourceUrl,
  total_markets: 0,
  current_index: 0,
  current_market: null,
  rows_found: 0,
  inserted: 0,
  updated: 0,
  unchanged: 0,
  errors: 0,
  last_error: null,
  logs: []
};

function writeStatus() {
  fs.mkdirSync(RUNTIME_DIR, { recursive: true });
  status.updated_at = new Date().toISOString();
  fs.writeFileSync(STATUS_FILE, JSON.stringify(status, null, 2));
}

function log(msg) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
  status.logs.push(line);
  if (status.logs.length > 80) status.logs = status.logs.slice(-80);
  writeStatus();
}

function assertAllowedUrl(rawUrl) {
  const u = new URL(String(rawUrl || '').trim());
  if (u.protocol !== 'https:') throw new Error('URL harus https.');
  if (!/^prediksi\d+\.angka-alexis\.pro$/i.test(u.hostname)) throw new Error('Domain sumber tidak diizinkan.');
  return u.toString();
}

function parseDate(value) {
  let raw = String(value || '').trim().toLowerCase();
  raw = raw
    .replace(/senin|selasa|rabu|kamis|jumat|jum'at|sabtu|minggu|monday|tuesday|wednesday|thursday|friday|saturday|sunday/g, '')
    .replace(/,/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  let m = raw.match(/(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (m) return `${m[1]}-${m[2].padStart(2,'0')}-${m[3].padStart(2,'0')}`;

  m = raw.match(/(\d{1,2})[-/](\d{1,2})[-/](\d{4})/);
  if (m) return `${m[3]}-${m[2].padStart(2,'0')}-${m[1].padStart(2,'0')}`;

  m = raw.match(/(\d{1,2})[-\s]+([a-z]+)[-\s]+(\d{4})/);
  if (m && MONTHS[m[2]]) return `${m[3]}-${MONTHS[m[2]]}-${m[1].padStart(2,'0')}`;

  return null;
}

function cleanResult(value) {
  const raw = String(value || '').trim();
  if (/^\d{1,2}:\d{2}/.test(raw)) return null;
  const digits = raw.replace(/\D/g, '');
  if (!/^[0-9]{2,7}$/.test(digits)) return null;
  return digits;
}

function ownText($, el) {
  const clone = $(el).clone();
  clone.children().remove();
  return clone.text().replace(/\s+/g, ' ').trim();
}

function detectMarketName($, fallbackMarket) {
  let name = '';
  $('body *').each((_, el) => {
    if (name) return;
    const text = ownText($, el);
    const m = text.match(/RESULT\s+LENGKAP\s+([A-Z0-9:\-\s]+)/i);
    if (m) name = m[1].replace(/\s+/g, ' ').trim();
  });
  return name || fallbackMarket || 'manual-source';
}

function extractRows(html, marketContext) {
  const $ = cheerio.load(String(html || ''));
  const marketName = detectMarketName($, marketContext?.source_name || marketContext?.canonical_market_name || 'manual-source');
  const rows = [];

  $('table tr').each((_, tr) => {
    const cells = $(tr).find('td,th').map((__, td) => $(td).text().replace(/\s+/g, ' ').trim()).get();
    if (cells.length < 3) return;

    const joined = cells.join(' ');
    if (/hari\s+tanggal\s+prize/i.test(joined)) return;

    let drawDate = null;
    let result = null;
    let resultTime = null;

    for (const cell of cells) if (!drawDate) drawDate = parseDate(cell);
    for (const cell of cells) {
      const r = cleanResult(cell);
      if (r && !parseDate(cell)) { result = r; break; }
    }
    for (const cell of cells) {
      if (/^\d{1,2}:\d{2}/.test(cell)) { resultTime = cell; break; }
    }

    if (drawDate && result) {
      rows.push({
        canonical_market_id: marketContext?.canonical_market_id || null,
        canonical_market_code: marketContext?.canonical_market_code || normalizeMarketCode(marketContext?.canonical_market_name || marketName),
        canonical_market_name: marketContext?.canonical_market_name || titleCase(marketName),
        source_name: marketContext?.source_name || titleCase(marketName),
        source_value: marketContext?.source_value || marketContext?.canonical_market_code || normalizeMarketCode(marketName),
        source_code: marketContext?.source_code || normalizeMarketCode(marketContext?.source_value || marketContext?.canonical_market_code || marketName),
        draw_date: drawDate,
        result,
        result_time: resultTime,
        raw: { cells }
      });
    }
  });

  const unique = new Map();
  for (const row of rows) unique.set(`${row.canonical_market_code}|${row.draw_date}|${row.result}`, row);
  return [...unique.values()];
}

async function saveRows(poolInstance, rows, sourceUrl) {
  const client = await poolInstance.connect();
  let inserted = 0, updated = 0, unchanged = 0, conflicts = 0;

  try {
    for (const row of rows) {
      const saved = await saveCanonicalResult(client, {
        sourceUrl,
        source_tag: 'manual-fetch-all',
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
    }
  } finally {
    client.release();
  }

  return { inserted, updated, unchanged, conflicts };
}

async function resolveMarkets(client, sourceUrl) {
  const sourceMarkets = await fetchSourceMarketOptions(sourceUrl);
  const resolved = [];

  for (const opt of sourceMarkets) {
    const alias = await resolveAliasBySourceOption(client, sourceUrl, opt.source_value, opt.source_name);
    if (!alias) continue;
    resolved.push({ option: opt, alias });
  }

  return resolved;
}

async function main() {
  const url = assertAllowedUrl(sourceUrl);
  writeStatus();
  log('Mulai fetch semua pasaran: ' + url);

  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });

  try {
    const page = await browser.newPage({
      timezoneId: 'Asia/Jakarta',
      userAgent: 'Mozilla/5.0 BBFS-Shinobi-Manual-All/1.0'
    });

    await page.route('**/*', route => {
      const t = route.request().resourceType();
      if (['image','font','media'].includes(t)) return route.abort();
      return route.continue();
    });

    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.waitForTimeout(2500);

    const selectExists = await page.locator('#selectpasaran').count();
    if (!selectExists) throw new Error('Dropdown #selectpasaran tidak ditemukan.');

    const client = await pool.connect();
    let markets = [];
    try {
      markets = await resolveMarkets(client, url);
    } finally {
      client.release();
    }

    status.total_markets = markets.length;
    writeStatus();
    log('Total pasaran terdeteksi: ' + markets.length);

    for (let i = 0; i < markets.length; i++) {
      const market = markets[i];
      const alias = market.alias;
      status.current_index = i + 1;
      status.current_market = alias.canonical_market_code;
      writeStatus();

      try {
        log(`Fetch ${i + 1}/${markets.length}: ${alias.canonical_market_code} <= ${alias.source_value}`);
        await page.selectOption('#selectpasaran', alias.source_value || market.option.source_value);
        await page.waitForTimeout(2200);
        await page.waitForLoadState('networkidle', { timeout: 7000 }).catch(() => {});

        const html = await page.content();
        const rows = extractRows(html, {
          canonical_market_id: alias.canonical_market_id,
          canonical_market_code: alias.canonical_market_code,
          canonical_market_name: alias.canonical_market_name,
          source_name: alias.source_name,
          source_value: alias.source_value,
          source_code: alias.source_code
        });
        status.rows_found += rows.length;

        if (rows.length) {
          const saved = await saveRows(pool, rows, url);
          status.inserted += saved.inserted;
          status.updated += saved.updated;
          status.unchanged += saved.unchanged;
          log(`OK ${alias.canonical_market_code}: rows=${rows.length}, insert=${saved.inserted}, update=${saved.updated}, same=${saved.unchanged}, conflict=${saved.conflicts}`);
        } else {
          log(`NO ${alias.canonical_market_code}: 0 row`);
        }
      } catch (e) {
        status.errors += 1;
        status.last_error = `${alias.canonical_market_code}: ${e.message}`;
        log('ERROR ' + status.last_error);
      }
    }

    status.running = false;
    status.finished_at = new Date().toISOString();
    writeStatus();
    log('SELESAI fetch semua pasaran.');
  } finally {
    await browser.close().catch(() => {});
    await pool.end().catch(() => {});
  }
}

main().catch(async e => {
  status.running = false;
  status.finished_at = new Date().toISOString();
  status.errors += 1;
  status.last_error = e.message;
  writeStatus();
  log('FATAL: ' + e.message);
  await pool.end().catch(() => {});
  process.exit(1);
});
