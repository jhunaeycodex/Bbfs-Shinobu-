require('dotenv').config();

const { chromium } = require('playwright');
const { Pool } = require('pg');

const SOURCE_URL = process.env.FIX_SOURCE_URL || process.argv[2] || 'https://prediksi90.angka-alexis.pro/?page=data-keluaran-togel';
const DAYS = Number(process.env.FIX_DAYS || process.argv[3] || 30);
const LIMIT_MARKETS = Number(process.env.FIX_LIMIT_MARKETS || 0);
const START_FROM = String(process.env.FIX_START_FROM || '').trim();
const HEADLESS = String(process.env.FIX_HEADLESS || 'true') !== 'false';

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

function slugify(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/&/g, 'and')
    .replace(/\+/g, 'plus')
    .replace(/[^a-z0-9:]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 120);
}

function titleCase(value) {
  return String(value || '')
    .trim()
    .replace(/[-_]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
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

function dateToMs(yyyyMmDd) {
  return new Date(`${yyyyMmDd}T00:00:00+07:00`).getTime();
}

function cutoffDate(days) {
  const now = new Date();
  const local = new Date(now.toLocaleString('en-US', { timeZone: 'Asia/Jakarta' }));
  local.setHours(0, 0, 0, 0);
  local.setDate(local.getDate() - (days - 1));
  const y = local.getFullYear();
  const m = String(local.getMonth() + 1).padStart(2, '0');
  const d = String(local.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

function parseRowsFromBodyText(text, marketCode, marketName, cutoff) {
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
    if (!drawDate) continue;
    if (dateToMs(drawDate) < dateToMs(cutoff)) continue;

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
  for (const row of rows) {
    unique.set(`${row.market_code}|${row.draw_date}|${row.result}`, row);
  }
  return [...unique.values()];
}

async function ensureMarket(client, code, name) {
  const found = await client.query('SELECT id FROM markets WHERE code = $1', [code]);
  if (found.rowCount > 0) return found.rows[0].id;

  const inserted = await client.query(`
    INSERT INTO markets (code, name, timezone, is_active, display_order)
    VALUES ($1, $2, 'Asia/Jakarta', TRUE, 999)
    ON CONFLICT (code)
    DO UPDATE SET name = EXCLUDED.name, updated_at = NOW()
    RETURNING id
  `, [code, name]);

  await client.query(`
    INSERT INTO market_profiles (market_id)
    VALUES ($1)
    ON CONFLICT (market_id) DO NOTHING
  `, [inserted.rows[0].id]);

  return inserted.rows[0].id;
}

async function saveRows(rows, sourceUrl) {
  const client = await pool.connect();

  let inserted = 0;
  let updated = 0;
  let unchanged = 0;

  try {
    for (const row of rows) {
      const marketId = await ensureMarket(client, row.market_code, row.market_name);

      const old = await client.query(
        'SELECT result FROM result_draws WHERE market_id = $1 AND draw_date = $2',
        [marketId, row.draw_date]
      );

      await client.query(`
        INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
        VALUES ($1, $2, $3, $4, $5::jsonb)
        ON CONFLICT (market_id, draw_date)
        DO UPDATE SET
          result = EXCLUDED.result,
          source = EXCLUDED.source,
          raw_payload = EXCLUDED.raw_payload,
          updated_at = NOW()
      `, [
        marketId,
        row.draw_date,
        row.result,
        'manual-fix-30-days',
        JSON.stringify({
          source_url: sourceUrl,
          result_time: row.result_time,
          raw_line: row.raw_line,
          fixed_at: new Date().toISOString()
        })
      ]);

      if (old.rowCount === 0) inserted++;
      else if (old.rows[0].result !== row.result) updated++;
      else unchanged++;
    }
  } finally {
    client.release();
  }

  return { inserted, updated, unchanged };
}

async function main() {
  const cutoff = cutoffDate(DAYS);

  console.log('SOURCE_URL:', SOURCE_URL);
  console.log('DAYS:', DAYS);
  console.log('CUTOFF:', cutoff);

  const browser = await chromium.launch({
    headless: HEADLESS,
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });

  const page = await browser.newPage({ userAgent: 'Mozilla/5.0' });

  await page.route('**/*', route => {
    const type = route.request().resourceType();
    if (['image', 'font', 'media'].includes(type)) return route.abort();
    return route.continue();
  });

  await page.goto(SOURCE_URL, { waitUntil: 'domcontentloaded', timeout: 90000 });

  const selectCount = await page.locator('#selectpasaran').count();
  if (!selectCount) {
    throw new Error('Dropdown #selectpasaran tidak ditemukan. Link sumber tidak cocok.');
  }

  let markets = await page.locator('#selectpasaran option').evaluateAll(options => {
    return options.map(o => ({
      value: o.value,
      text: (o.textContent || '').trim()
    })).filter(o => o.value && o.value !== '0' && o.value !== '');
  });

  markets = markets.map(m => ({
    code: slugify(m.value),
    value: m.value,
    name: titleCase(m.text || m.value)
  }));

  if (START_FROM) {
    const idx = markets.findIndex(m => m.code === START_FROM || m.value === START_FROM);
    if (idx >= 0) markets = markets.slice(idx);
  }

  if (LIMIT_MARKETS > 0) markets = markets.slice(0, LIMIT_MARKETS);

  console.log('TOTAL_MARKETS:', markets.length);

  let allRows = [];
  let failed = 0;

  for (let i = 0; i < markets.length; i++) {
    const market = markets[i];

    try {
      await page.selectOption('#selectpasaran', market.value);
      await page.waitForTimeout(1800);

      const text = await page.locator('body').innerText({ timeout: 20000 });
      const rows = parseRowsFromBodyText(text, market.code, market.name, cutoff);
      allRows.push(...rows);

      console.log(`[${i + 1}/${markets.length}] ${market.code}: ${rows.length} row`);

      if ((i + 1) % 10 === 0) {
        const saved = await saveRows(allRows, SOURCE_URL);
        console.log(`SAVE_BATCH rows=${allRows.length} inserted=${saved.inserted} updated=${saved.updated} unchanged=${saved.unchanged}`);
        allRows = [];
      }
    } catch (error) {
      failed++;
      console.log(`[${i + 1}/${markets.length}] FAIL ${market.code}: ${error.message}`);
    }
  }

  let finalSaved = { inserted: 0, updated: 0, unchanged: 0 };
  if (allRows.length) finalSaved = await saveRows(allRows, SOURCE_URL);

  await browser.close();
  await pool.end();

  console.log('FIX 30 HARI SELESAI');
  console.log({
    failed_markets: failed,
    inserted: finalSaved.inserted,
    updated: finalSaved.updated,
    unchanged: finalSaved.unchanged,
    note: 'Angka SAVE_BATCH di atas juga termasuk total simpan per batch.'
  });
}

main().catch(async error => {
  console.error('GAGAL:', error.message);
  await pool.end().catch(() => {});
  process.exit(1);
});
