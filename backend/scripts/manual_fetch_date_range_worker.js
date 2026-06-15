require('dotenv').config();

const fs = require('fs');
const { chromium } = require('playwright');
const { Pool } = require('pg');
const {
  fetchSourceMarketOptions,
  normalizeMarketCode,
  resolveAliasByCanonical,
  resolveAliasBySourceOption,
  saveCanonicalResult,
  titleCase
} = require('../market_alias');

const SOURCE_URL = process.env.SOURCE_URL || process.argv[2] || 'https://prediksi90.angka-alexis.pro/?page=data-keluaran-togel';
const MARKET = String(process.env.MARKET || process.argv[3] || '').trim();
const DATE_FROM = String(process.env.DATE_FROM || process.argv[4] || '').trim();
const DATE_TO = String(process.env.DATE_TO || process.argv[5] || '').trim();
const ALL_MARKETS = String(process.env.ALL_MARKETS || '').trim() === '1' || MARKET === '__ALL__';
const STATUS_FILE = process.env.STATUS_FILE || '/opt/bbfs-shinobi/manual_fetch_date_status.json';
const LOG_FILE = process.env.LOG_FILE || '/opt/bbfs-shinobi/manual_fetch_date.log';
let currentStep = 'init';

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10
});

const MONTHS = {
  jan: '01', januari: '01', january: '01',
  feb: '02', februari: '02', february: '02',
  mar: '03', maret: '03', march: '03',
  apr: '04', april: '04',
  mei: '05', may: '05',
  jun: '06', juni: '06', june: '06',
  jul: '07', juli: '07', july: '07',
  agu: '08', ags: '08', agustus: '08', august: '08',
  sep: '09', september: '09',
  okt: '10', oktober: '10', oct: '10', october: '10',
  nov: '11', november: '11',
  des: '12', desember: '12', dec: '12', december: '12'
};

function log(message, extra = null) {
  const line = extra ? `${new Date().toISOString()} ${message} ${JSON.stringify(extra)}` : `${new Date().toISOString()} ${message}`;
  console.log(line);
  try { fs.appendFileSync(LOG_FILE, line + '\n'); } catch (_) {}
}

function writeStatus(obj) {
  try {
    fs.writeFileSync(STATUS_FILE, JSON.stringify({
      updated_at: new Date().toISOString(),
      ...obj
    }, null, 2));
  } catch (_) {}
}

function normalizeDateInput(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;

  let m = raw.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (m) return raw;

  m = raw.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;

  return null;
}

function parseDate(rawValue) {
  let raw = String(rawValue || '').trim().toLowerCase();

  raw = raw
    .replace(/senin|selasa|rabu|kamis|jumat|jum'at|sabtu|minggu|monday|tuesday|wednesday|thursday|friday|saturday|sunday/g, '')
    .replace(/,/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  let m = raw.match(/(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (m) return `${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}`;

  m = raw.match(/(\d{1,2})[-/](\d{1,2})[-/](\d{4})/);
  if (m) return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;

  m = raw.match(/(\d{1,2})[-\s]+([a-z]+)[-\s]+(\d{4})/);
  if (m && MONTHS[m[2]]) return `${m[3]}-${MONTHS[m[2]]}-${m[1].padStart(2, '0')}`;

  return null;
}

function cleanResult(rawValue) {
  const raw = String(rawValue || '').trim();
  if (/^\d{1,2}:\d{2}/.test(raw)) return null;
  const digits = raw.replace(/\D/g, '');
  if (!/^[0-9]{2,7}$/.test(digits)) return null;
  return digits;
}

function toMs(yyyyMmDd) {
  return new Date(`${yyyyMmDd}T00:00:00+07:00`).getTime();
}

function inDateRange(drawDate, dateFrom, dateTo) {
  if (!drawDate) return false;
  const t = toMs(drawDate);
  if (dateFrom && t < toMs(dateFrom)) return false;
  if (dateTo && t > toMs(dateTo)) return false;
  return true;
}

function parseRowsFromBodyText(text, marketCode, marketName, dateFrom, dateTo) {
  const rows = [];
  const lines = String(text || '')
    .split(/\r?\n/)
    .map(x => x.trim())
    .filter(Boolean);

  for (const line of lines) {
    if (!/\d{1,2}[-\s\/][A-Za-z0-9]+[-\s\/]\d{4}/.test(line) && !/\d{4}[-\/]\d{1,2}[-\/]\d{1,2}/.test(line)) {
      continue;
    }

    const drawDate = parseDate(line);
    if (!inDateRange(drawDate, dateFrom, dateTo)) continue;

    const tokens = line.split(/\s+/);
    let result = null;
    let resultTime = null;

    for (const token of tokens) {
      if (!resultTime && /^\d{1,2}:\d{2}/.test(token)) resultTime = token;
    }

    for (const token of tokens) {
      const candidate = cleanResult(token);
      if (!candidate) continue;
      if (/^\d{4}$/.test(token) && line.includes(`-${token}`)) continue;
      if (candidate.length >= 2 && !/^\d{1,2}:\d{2}/.test(token)) {
        result = candidate;
        break;
      }
    }

    if (!result) continue;

    rows.push({
      market_code: marketCode,
      market_name: marketName,
      draw_date: drawDate,
      result,
      result_time: resultTime,
      raw_line: line
    });
  }

  const unique = new Map();
  for (const row of rows) unique.set(`${row.market_code}|${row.draw_date}|${row.result}`, row);
  return [...unique.values()];
}

async function saveRows(poolInstance, rows, sourceUrl, sourceTag) {
  const client = await poolInstance.connect();
  let inserted = 0;
  let updated = 0;
  let unchanged = 0;
  let conflicts = 0;

  try {
    for (const row of rows) {
      const saved = await saveCanonicalResult(client, {
        sourceUrl,
        source_tag: sourceTag,
        canonical_market_id: row.canonical_market_id,
        canonical_market_code: row.canonical_market_code,
        canonical_market_name: row.canonical_market_name,
        source_name: row.source_name,
        source_value: row.source_value,
        source_code: row.source_code,
        draw_date: row.draw_date,
        result: row.result,
        raw: {
          result_time: row.result_time,
          raw_line: row.raw_line,
          raw_cells: row.raw_cells || []
        }
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

async function resolveMarkets(client, sourceUrl, marketFilter) {
  const sourceMarkets = await fetchSourceMarketOptions(sourceUrl);

  if (ALL_MARKETS) {
    const resolved = [];
    for (const opt of sourceMarkets) {
      const alias = await resolveAliasBySourceOption(client, sourceUrl, opt.source_value, opt.source_name);
      if (!alias) continue;
      resolved.push({ option: opt, alias });
    }
    return resolved;
  }

  const alias = await resolveAliasByCanonical(client, sourceUrl, marketFilter);
  if (!alias) return [];
  return [{
    option: {
      source_name: alias.source_name,
      source_value: alias.source_value,
      source_code: alias.source_code
    },
    alias
  }];
}


async function parseRowsFromPrize1Table(page, marketContext, dateFrom, dateTo) {
  const tableRows = await page.evaluate(() => {
    return Array.from(document.querySelectorAll('table')).flatMap(table => {
      const rows = Array.from(table.querySelectorAll('tr')).map(tr => {
        return Array.from(tr.querySelectorAll('th,td')).map(td =>
          (td.innerText || td.textContent || '').replace(/\s+/g, ' ').trim()
        );
      });
      return rows;
    });
  });

  const rows = [];
  let header = null;
  let dateIdx = 1;
  let prizeIdx = 2;
  let timeIdx = 3;

  for (const cells of tableRows) {
    const joined = cells.join(' ').toLowerCase();

    if (joined.includes('tanggal') && joined.includes('prize')) {
      header = cells.map(x => String(x || '').toLowerCase());

      const foundDate = header.findIndex(x => x.includes('tanggal') || x.includes('date'));
      const foundPrize = header.findIndex(x => x.includes('prize') || x.includes('result'));
      const foundTime = header.findIndex(x => x.includes('jam') || x.includes('time'));

      if (foundDate >= 0) dateIdx = foundDate;
      if (foundPrize >= 0) prizeIdx = foundPrize;
      if (foundTime >= 0) timeIdx = foundTime;

      continue;
    }

    if (cells.length < 3) continue;

    const dateRaw = cells[dateIdx] || '';
    const prizeRaw = cells[prizeIdx] || '';
    const timeRaw = cells[timeIdx] || '';

    const drawDate = parseDate(dateRaw);
    if (!inDateRange(drawDate, dateFrom, dateTo)) continue;

    const result = String(prizeRaw || '').replace(/\D/g, '');

    // KUNCI UTAMA: result hanya dari kolom Prize 1 dan wajib 4D.
    if (!/^[0-9]{4}$/.test(result)) continue;

    rows.push({
        canonical_market_id: marketContext.canonical_market_id,
        canonical_market_code: marketContext.canonical_market_code,
        canonical_market_name: marketContext.canonical_market_name,
        source_name: marketContext.source_name,
        source_value: marketContext.source_value,
        source_code: marketContext.source_code,
        draw_date: drawDate,
        result,
        result_time: timeRaw,
        raw_line: cells.join(' | '),
        raw_cells: cells
      });
  }

  const unique = new Map();
  for (const row of rows) {
    unique.set(`${row.canonical_market_code}|${row.draw_date}`, row);
  }

  return [...unique.values()];
}


async function main() {
  const dateFrom = normalizeDateInput(DATE_FROM);
  const dateTo = normalizeDateInput(DATE_TO);

  if (!dateFrom || !dateTo) {
    throw new Error('Tanggal awal dan tanggal akhir wajib diisi format YYYY-MM-DD.');
  }

  if (toMs(dateFrom) > toMs(dateTo)) {
    throw new Error('Tanggal awal tidak boleh lebih besar dari tanggal akhir.');
  }

  writeStatus({
    status: 'running',
    source_url: SOURCE_URL,
    date_from: dateFrom,
    date_to: dateTo,
    mode: ALL_MARKETS ? 'all' : 'one',
    market: MARKET || null,
    total_markets: 0,
    done_markets: 0,
    inserted: 0,
    updated: 0,
    unchanged: 0,
    failed: 0
  });

  log('START', { source_url: SOURCE_URL, date_from: dateFrom, date_to: dateTo, all: ALL_MARKETS, market: MARKET });

  currentStep = 'launch_browser';
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });

  currentStep = 'open_page';
  const page = await browser.newPage({ userAgent: 'Mozilla/5.0' });

  await page.route('**/*', route => {
    const type = route.request().resourceType();
    if (['image', 'font', 'media'].includes(type)) return route.abort();
    return route.continue();
  });

  currentStep = 'goto_source';
  await page.goto(SOURCE_URL, { waitUntil: 'domcontentloaded', timeout: 90000 });

  currentStep = 'read_dropdown';
  const selectCount = await page.locator('#selectpasaran').count();
  if (!selectCount) throw new Error('Dropdown #selectpasaran tidak ditemukan.');

  const client = await pool.connect();
  let markets = [];

  try {
    currentStep = 'resolve_markets';
    markets = await resolveMarkets(client, SOURCE_URL, MARKET);
  } finally {
    client.release();
  }

  if (!markets.length) {
    throw new Error(ALL_MARKETS ? 'Tidak ada alias aktif yang cocok dari sumber.' : 'Alias aktif untuk pasaran canonical ini tidak ditemukan.');
  }

  let totalInserted = 0;
  let totalUpdated = 0;
  let totalUnchanged = 0;
  let failed = 0;
  const samples = [];

  writeStatus({
    status: 'running',
    source_url: SOURCE_URL,
    date_from: dateFrom,
    date_to: dateTo,
    mode: ALL_MARKETS ? 'all' : 'one',
    total_markets: markets.length,
    done_markets: 0,
    inserted: 0,
    updated: 0,
    unchanged: 0,
    failed: 0
  });

  for (let i = 0; i < markets.length; i++) {
    const market = markets[i];
    const alias = market.alias;

    try {
      currentStep = `fetch_market:${alias.canonical_market_code}`;
      await page.selectOption('#selectpasaran', alias.source_value || market.option.source_value);
      await page.waitForTimeout(1800);

      const rows = await parseRowsFromPrize1Table(page, {
        canonical_market_id: alias.canonical_market_id,
        canonical_market_code: alias.canonical_market_code,
        canonical_market_name: alias.canonical_market_name,
        source_name: alias.source_name,
        source_value: alias.source_value,
        source_code: alias.source_code
      }, dateFrom, dateTo);
      const saved = await saveRows(pool, rows, SOURCE_URL, 'manual-date-range');

      totalInserted += saved.inserted;
      totalUpdated += saved.updated;
      totalUnchanged += saved.unchanged;

      for (const row of rows.slice(0, 3)) samples.push(row);

      log('MARKET_DONE', {
        no: i + 1,
        total: markets.length,
        market: alias.canonical_market_code,
        source_value: alias.source_value,
        rows: rows.length,
        ...saved
      });
    } catch (error) {
      failed++;
      log('MARKET_FAIL', { no: i + 1, total: markets.length, market: alias?.canonical_market_code || MARKET, error: error.message });
    }

    writeStatus({
      status: 'running',
      source_url: SOURCE_URL,
      date_from: dateFrom,
      date_to: dateTo,
      mode: ALL_MARKETS ? 'all' : 'one',
      total_markets: markets.length,
      done_markets: i + 1,
      current_market: alias?.canonical_market_code || MARKET,
      inserted: totalInserted,
      updated: totalUpdated,
      unchanged: totalUnchanged,
      failed
    });
  }

  await browser.close();

  const result = {
    ok: true,
    status: 'completed',
    source_url: SOURCE_URL,
    date_from: dateFrom,
    date_to: dateTo,
    mode: ALL_MARKETS ? 'all' : 'one',
    total_markets: markets.length,
    inserted: totalInserted,
    updated: totalUpdated,
    unchanged: totalUnchanged,
    failed,
    sample: samples.slice(0, 20)
  };

  writeStatus(result);
  log('DONE', result);

  await pool.end();
  console.log(JSON.stringify(result, null, 2));
}

main().catch(async error => {
  const result = { ok: false, status: 'failed', stage: currentStep, error: error.message };
  writeStatus(result);
  log('FAILED', result);
  await pool.end().catch(() => {});
  console.error(JSON.stringify(result, null, 2));
  process.exit(1);
});
