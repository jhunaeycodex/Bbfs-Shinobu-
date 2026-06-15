require('dotenv').config();

const axios = require('axios');
const cheerio = require('cheerio');
const { Pool } = require('pg');

const BASE = 'https://prediksi89.angka-alexis.pro';
const SOURCE_URL = `${BASE}/?page=data-keluaran-togel`;
const ENDPOINT = `${BASE}/assets/search-jp.php`;
const DRY_RUN = process.argv.includes('--dry-run');
const LIMIT = Number(process.env.SOURCE_LIMIT_MARKETS || 0);

const FALLBACK_MARKETS = `indiana-mid totomacau-00 kentucky-mid tennesse-mid texas-day rhode-island florida-mid pennsylvania-day illinois-mid missouri-mid washington-mid delaware-day virginia-day wisconsin newyork-mid carolina-day oregon3 pennsylvania-eve oregon6 georgia-eve texas-eve tennesse-eve ohio-eve michigan-eve maryland-eve delaware-night washington-eve florida-eve california missouri-eve oregon9 kupang illinois-eve newyork-eve indiana-eve newjersey-eve virginia-night kentucky-eve texas-night carolina-eve georgia-night thailand-lotteries cambodia oregon12 totomacau-13 bullseye sydney nusa-toto totomacau-15-5d china korea totomacau-16 nusa japan singapore singapore-25 jakarta totomacau-19 mongolia vietnam pcso taiwan totomacau-21-5d tennesse-mor jepang texas-mor totomacau-22 hongkong maryland-mid georgia-mid ohio-mid newjersey-mid michigan-mid totomacau-23 kingkong-17 kingkong-23 boston munchen freetown moscow kingston germany atlanta north-korea phoenix4d portland buffalo4d bogota lima oslo-pools totomacau-21:30---5d`
  .split(/\s+/)
  .filter(Boolean);

const MONTHS = {
  jan:'01', january:'01', januari:'01',
  feb:'02', february:'02', februari:'02',
  mar:'03', march:'03', maret:'03',
  apr:'04', april:'04',
  may:'05', mei:'05',
  jun:'06', june:'06', juni:'06',
  jul:'07', july:'07', juli:'07',
  aug:'08', august:'08', agu:'08', agustus:'08',
  sep:'09', september:'09',
  oct:'10', october:'10', okt:'10', oktober:'10',
  nov:'11', november:'11',
  dec:'12', december:'12', des:'12', desember:'12'
};

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 5
});

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

function parseDate(value) {
  let raw = String(value || '').trim().toLowerCase();
  raw = raw
    .replace(/senin|selasa|rabu|kamis|jumat|jum'at|sabtu|minggu|monday|tuesday|wednesday|thursday|friday|saturday|sunday/g, '')
    .replace(/,/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  let m = raw.match(/(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})/);
  if (m) return `${m[1]}-${m[2].padStart(2,'0')}-${m[3].padStart(2,'0')}`;

  m = raw.match(/(\d{1,2})[-\/](\d{1,2})[-\/](\d{4})/);
  if (m) return `${m[3]}-${m[2].padStart(2,'0')}-${m[1].padStart(2,'0')}`;

  m = raw.match(/(\d{1,2})[-\s]+([a-z]+)[-\s]+(\d{4})/);
  if (m && MONTHS[m[2]]) return `${m[3]}-${MONTHS[m[2]]}-${m[1].padStart(2,'0')}`;

  return null;
}

function cleanResult(value) {
  const raw = String(value || '').trim();
  if (/^\d{1,2}:\d{2}/.test(raw)) return null;
  if (/\d{1,2}[-\s]+[a-zA-Z]{3,9}[-\s]+\d{4}/.test(raw)) return null;
  const digits = raw.replace(/\D/g, '');
  if (!/^[0-9]{2,7}$/.test(digits)) return null;
  return digits;
}

async function httpGet(url) {
  return axios.get(url, {
    timeout: 60000,
    maxContentLength: Infinity,
    maxBodyLength: Infinity,
    headers: {
      'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0',
      'Accept': 'text/html,*/*'
    }
  });
}

async function detectMarkets() {
  try {
    const res = await httpGet(SOURCE_URL);
    const text = cheerio.load(res.data).text().replace(/\s+/g, ' ');
    const m = text.match(/Pilih Pasaran\s+(.+?)\s+Mohon ditunggu/i);
    if (m) {
      const markets = m[1]
        .split(/\s+/)
        .map(x => slugify(x))
        .filter(x => /^[a-z0-9][a-z0-9:-]*$/.test(x));
      if (markets.length > 0) return [...new Set(markets)];
    }
  } catch (e) {
    console.log('Market detect dari HTML gagal, pakai fallback:', e.message);
  }
  return FALLBACK_MARKETS;
}

async function fetchMarketHtml(market) {
  const body = new URLSearchParams({ bukti: market }).toString();
  const res = await axios.post(ENDPOINT, body, {
    timeout: 30000,
    maxContentLength: Infinity,
    maxBodyLength: Infinity,
    validateStatus: s => s >= 200 && s < 500,
    headers: {
      'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0',
      'Accept': 'text/html,*/*',
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest',
      'Origin': BASE,
      'Referer': SOURCE_URL
    }
  });

  return String(res.data || '');
}

function parseRowsFromHtml(html, market) {
  const $ = cheerio.load(html);
  const rows = [];

  $('tr').each((_, tr) => {
    const cells = $(tr).find('td,th').map((__, td) => $(td).text().replace(/\s+/g, ' ').trim()).get();
    if (cells.length < 3) return;

    const joined = cells.join(' ');
    if (/hari\s+tanggal\s+prize/i.test(joined)) return;

    const drawDate = cells.map(parseDate).find(Boolean) || parseDate(joined);
    if (!drawDate) return;

    let result = null;
    for (const cell of cells) {
      const r = cleanResult(cell);
      if (r && !parseDate(cell)) {
        result = r;
        break;
      }
    }
    if (!result) return;

    const resultTime = cells.find(c => /^\d{1,2}:\d{2}/.test(c)) || null;

    rows.push({
      market_code: slugify(market),
      market_name: titleCase(market),
      draw_date: drawDate,
      result,
      result_time: resultTime,
      raw: { cells }
    });
  });

  if (rows.length === 0) {
    const text = $.text().replace(/\s+/g, ' ');
    const re = /(Senin|Selasa|Rabu|Kamis|Jumat|Sabtu|Minggu|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)?\s*(\d{1,2}[-\s][A-Za-z]{3,9}[-\s]\d{4}|\d{4}[-\/]\d{1,2}[-\/]\d{1,2}|\d{1,2}[-\/]\d{1,2}[-\/]\d{4})\s+(\d{2,7})\s+(\d{1,2}:\d{2}:\d{2})?/gi;
    let m;
    while ((m = re.exec(text))) {
      const date = parseDate(m[2]);
      const result = cleanResult(m[3]);
      if (date && result) {
        rows.push({
          market_code: slugify(market),
          market_name: titleCase(market),
          draw_date: date,
          result,
          result_time: m[4] || null,
          raw: { match: m[0] }
        });
      }
    }
  }

  const unique = new Map();
  for (const row of rows) unique.set(`${row.market_code}|${row.draw_date}|${row.result}`, row);
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

async function saveRows(rows) {
  const client = await pool.connect();
  let inserted = 0, updated = 0, unchanged = 0;

  try {
    for (const row of rows) {
      const marketId = await ensureMarket(client, row.market_code, row.market_name);
      const old = await client.query('SELECT result FROM result_draws WHERE market_id=$1 AND draw_date=$2', [marketId, row.draw_date]);

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
        'auto-source:alexis-search-jp',
        JSON.stringify({ source_url: ENDPOINT, result_time: row.result_time, raw: row.raw })
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
  let markets = await detectMarkets();
  markets = [...new Set(markets)];
  if (LIMIT > 0) markets = markets.slice(0, LIMIT);

  console.log('Markets detected:', markets.length);

  const allRows = [];
  for (const market of markets) {
    try {
      const html = await fetchMarketHtml(market);
      const rows = parseRowsFromHtml(html, market);
      if (rows.length > 0) {
        console.log(`OK ${market}: ${rows.length} row`);
        allRows.push(...rows);
      } else {
        console.log(`NO ${market}`);
      }
    } catch (e) {
      console.log(`ERR ${market}: ${e.message}`);
    }
  }

  const unique = new Map();
  for (const row of allRows) unique.set(`${row.market_code}|${row.draw_date}|${row.result}`, row);
  const rows = [...unique.values()];

  console.log('Fetched rows:', rows.length);

  if (DRY_RUN) {
    console.log('DRY RUN. Database belum diubah. Contoh 20 row:');
    console.log(JSON.stringify(rows.slice(0, 20), null, 2));
    await pool.end();
    return;
  }

  if (rows.length === 0) {
    console.log('Tidak ada rows. Database tidak diubah.');
    await pool.end();
    return;
  }

  const saved = await saveRows(rows);
  console.log('AUTO FETCH SELESAI');
  console.log({ total: rows.length, ...saved });
  await pool.end();
}

main().catch(async err => {
  console.error('AUTO FETCH GAGAL:', err.message);
  await pool.end().catch(() => {});
  process.exit(1);
});
