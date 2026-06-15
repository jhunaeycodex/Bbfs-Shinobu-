require('dotenv').config();

const axios = require('axios');
const cheerio = require('cheerio');
const { chromium } = require('playwright');
const { DateTime } = require('luxon');
const { Pool } = require('pg');

const SOURCE_NAME = 'alexis';
const RESULT_URL = 'https://prediksi89.angka-alexis.pro/?page=data-keluaran-togel';
const SCHEDULE_URL = 'https://prediksi89.angka-alexis.pro/?page=jadwal-togel';
const DRY_RUN = process.argv.includes('--dry-run');
const LIMIT_MARKETS = Number(process.env.SOURCE_LIMIT_MARKETS || 0);

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 10
});

function slugify(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/&/g, 'and')
    .replace(/\+/g, 'plus')
    .replace(/[^a-z0-9]+/g, '-')
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

function canonicalMarket(value) {
  return slugify(value)
    .replace(/-dc-/g, '-')
    .replace(/-midday$/g, '-mid')
    .replace(/-midday-/g, '-mid-')
    .replace(/-evening$/g, '-eve')
    .replace(/-evening-/g, '-eve-')
    .replace(/-morning$/g, '-mor')
    .replace(/-morning-/g, '-mor-')
    .replace(/^new-york/g, 'newyork')
    .replace(/^new-jersey/g, 'newjersey')
    .replace(/^rhode-island/g, 'rhode-island')
    .replace(/^jepang$/g, 'japan')
    .replace(/-lottery$/g, '-lotteries');
}

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

function parseDate(value) {
  let raw = String(value || '').trim().toLowerCase();

  raw = raw
    .replace(/senin|selasa|rabu|kamis|jumat|jum'at|sabtu|minggu|monday|tuesday|wednesday|thursday|friday|saturday|sunday/g, '')
    .replace(/,/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  let m = raw.match(/(\d{4})[-/](\d{1,2})[-/](\d{1,2})/);
  if (m) {
    return `${m[1]}-${m[2].padStart(2, '0')}-${m[3].padStart(2, '0')}`;
  }

  m = raw.match(/(\d{1,2})[-/](\d{1,2})[-/](\d{4})/);
  if (m) {
    return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  }

  m = raw.match(/(\d{1,2})\s+([a-z]+)\s+(\d{4})/);
  if (m && MONTHS[m[2]]) {
    return `${m[3]}-${MONTHS[m[2]]}-${m[1].padStart(2, '0')}`;
  }

  return null;
}

function cleanResult(value) {
  const digits = String(value || '').replace(/\D/g, '');

  if (!/^[0-9]{2,7}$/.test(digits)) return null;

  return digits;
}

function cleanTime(value) {
  const raw = String(value || '').trim().replace(/\./g, ':');
  const m = raw.match(/(\d{1,2}):?(\d{2}):?(\d{2})?/);
  if (!m) return null;

  return `${m[1].padStart(2, '0')}:${m[2]}:${m[3] || '00'}`;
}

function isLikelyScheduleText(value) {
  return /jadwal|tutup|undi|wib|situs resmi/i.test(String(value || ''));
}

async function loadMarketIndex(client) {
  const markets = await client.query('SELECT id, code, name FROM markets');
  const aliases = await client.query(`
    SELECT source_market_code, market_id
    FROM source_market_aliases
    WHERE source_name = $1
  `, [SOURCE_NAME]);

  return {
    markets: markets.rows,
    aliases: new Map(aliases.rows.map(x => [x.source_market_code, x.market_id]))
  };
}

async function ensureMarket(client, index, sourceCode, sourceName) {
  if (index.aliases.has(sourceCode)) {
    return index.aliases.get(sourceCode);
  }

  const canonicalSource = canonicalMarket(sourceCode || sourceName);

  let found = index.markets.find(m => m.code === sourceCode);

  if (!found) {
    found = index.markets.find(m =>
      canonicalMarket(m.code) === canonicalSource ||
      canonicalMarket(m.name) === canonicalSource
    );
  }

  if (found) {
    if (!DRY_RUN) {
      await client.query(`
        INSERT INTO source_market_aliases (source_name, source_market_code, source_market_name, market_id)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (source_name, source_market_code)
        DO UPDATE SET source_market_name = EXCLUDED.source_market_name
      `, [SOURCE_NAME, sourceCode, sourceName, found.id]);
    }

    index.aliases.set(sourceCode, found.id);
    return found.id;
  }

  if (DRY_RUN) return null;

  const inserted = await client.query(`
    INSERT INTO markets (code, name, timezone, is_active, display_order)
    VALUES ($1, $2, 'Asia/Jakarta', TRUE, 999)
    ON CONFLICT (code)
    DO UPDATE SET name = EXCLUDED.name, updated_at = NOW()
    RETURNING id, code, name
  `, [sourceCode, titleCase(sourceName || sourceCode)]);

  await client.query(`
    INSERT INTO market_profiles (market_id)
    VALUES ($1)
    ON CONFLICT (market_id) DO NOTHING
  `, [inserted.rows[0].id]);

  await client.query(`
    INSERT INTO source_market_aliases (source_name, source_market_code, source_market_name, market_id)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (source_name, source_market_code)
    DO UPDATE SET source_market_name = EXCLUDED.source_market_name
  `, [SOURCE_NAME, sourceCode, sourceName, inserted.rows[0].id]);

  index.markets.push(inserted.rows[0]);
  index.aliases.set(sourceCode, inserted.rows[0].id);

  return inserted.rows[0].id;
}

function extractResultRowsFromHtml(html, marketHint) {
  const $ = cheerio.load(html);
  const rows = [];

  $('table tr').each((_, tr) => {
    const cells = $(tr).find('th,td').map((__, td) => $(td).text().trim()).get();

    if (cells.length < 2) return;

    const rowText = cells.join(' ');
    if (isLikelyScheduleText(rowText)) return;

    let date = null;
    let result = null;
    let marketName = marketHint?.name || '';
    let marketCode = marketHint?.code || '';

    for (const cell of cells) {
      if (!date) date = parseDate(cell);
    }

    for (const cell of [...cells].reverse()) {
      const maybe = cleanResult(cell);
      if (maybe && !parseDate(cell) && !/^\d{1,2}[:.]\d{2}/.test(cell)) {
        result = maybe;
        break;
      }
    }

    if (!marketName) {
      const candidate = cells.find(c => !parseDate(c) && !cleanResult(c) && !isLikelyScheduleText(c));
      if (candidate) {
        marketName = candidate;
        marketCode = slugify(candidate);
      }
    }

    if (date && result && marketName) {
      rows.push({
        market_code: marketCode || slugify(marketName),
        market_name: marketName,
        draw_date: date,
        result,
        raw: { cells }
      });
    }
  });

  if (rows.length === 0) {
    const text = $.text().replace(/\s+/g, ' ');
    const dateMatches = [...text.matchAll(/(\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[-/]\d{1,2}[-/]\d{4}|\d{1,2}\s+[A-Za-z]+\s+\d{4})/g)];

    for (const dm of dateMatches) {
      const start = Math.max(0, dm.index - 120);
      const end = Math.min(text.length, dm.index + 180);
      const segment = text.slice(start, end);
      const date = parseDate(dm[1]);
      const resultMatch = segment.match(/\b([0-9]{2,7})\b/g);

      if (!date || !resultMatch || !marketHint?.name) continue;

      const result = cleanResult(resultMatch[resultMatch.length - 1]);

      if (result) {
        rows.push({
          market_code: marketHint.code,
          market_name: marketHint.name,
          draw_date: date,
          result,
          raw: { segment }
        });
      }
    }
  }

  const unique = new Map();

  for (const row of rows) {
    const key = `${row.market_code}|${row.draw_date}|${row.result}`;
    unique.set(key, row);
  }

  return [...unique.values()];
}

async function syncSchedules(client) {
  const response = await axios.get(SCHEDULE_URL, {
    timeout: 30000,
    headers: {
      'User-Agent': 'Mozilla/5.0 BBFS-Shinobi-Bot/1.0'
    }
  });

  const $ = cheerio.load(response.data);
  const schedules = [];

  $('table tr').each((_, tr) => {
    const cells = $(tr).find('td,th').map((__, td) => $(td).text().trim()).get();
    if (cells.length < 3) return;

    const marketName = cells[0];
    const closeTime = cleanTime(cells[1]);
    const drawTime = cleanTime(cells[2]);

    if (!marketName || !closeTime || !drawTime) return;
    if (/nama pasaran/i.test(marketName)) return;

    schedules.push({
      market_code: slugify(marketName),
      market_name: marketName,
      close_time: closeTime,
      draw_time: drawTime
    });
  });

  if (schedules.length === 0) {
    const text = $.text().replace(/\s+/g, ' ');
    const re = /([a-z0-9][a-z0-9:-]*(?:-[a-z0-9:]+)*)\s+(\d{1,2}[:.]\d{2}:?\d{0,2})\s*WIB\s+(\d{1,2}[:.]\d{2}:?\d{0,2})\s*WIB/gi;
    let m;

    while ((m = re.exec(text))) {
      schedules.push({
        market_code: slugify(m[1]),
        market_name: m[1],
        close_time: cleanTime(m[2]),
        draw_time: cleanTime(m[3])
      });
    }
  }

  if (!DRY_RUN) {
    for (const item of schedules) {
      await client.query(`
        INSERT INTO source_market_schedules (
          source_name, market_code, market_name, close_time, draw_time, timezone, source_url, last_synced_at
        )
        VALUES ($1, $2, $3, $4, $5, 'Asia/Jakarta', $6, NOW())
        ON CONFLICT (source_name, market_code)
        DO UPDATE SET
          market_name = EXCLUDED.market_name,
          close_time = EXCLUDED.close_time,
          draw_time = EXCLUDED.draw_time,
          source_url = EXCLUDED.source_url,
          last_synced_at = NOW()
      `, [SOURCE_NAME, item.market_code, item.market_name, item.close_time, item.draw_time, SCHEDULE_URL]);
    }
  }

  return schedules.length;
}

async function fetchDynamicResults() {
  const browser = await chromium.launch({
    headless: true,
    args: ['--no-sandbox', '--disable-dev-shm-usage']
  });

  const page = await browser.newPage({
    timezoneId: 'Asia/Jakarta',
    userAgent: 'Mozilla/5.0 BBFS-Shinobi-Bot/1.0'
  });

  const allRows = [];

  try {
    await page.goto(RESULT_URL, {
      waitUntil: 'networkidle',
      timeout: 60000
    });

    await page.waitForTimeout(2500);

    const selectInfo = await page.evaluate(() => {
      return Array.from(document.querySelectorAll('select')).map((s, idx) => ({
        idx,
        count: s.options.length
      })).sort((a, b) => b.count - a.count);
    });

    const bestSelect = selectInfo.find(x => x.count > 5);

    if (!bestSelect) {
      const html = await page.content();
      allRows.push(...extractResultRowsFromHtml(html, null));
      return allRows;
    }

    let options = await page.evaluate((idx) => {
      const s = document.querySelectorAll('select')[idx];
      return Array.from(s.options).map(o => ({
        value: o.value,
        text: o.textContent.trim()
      })).filter(o => o.value || o.text);
    }, bestSelect.idx);

    options = options
      .filter(o => !/pilih|select/i.test(o.text))
      .map(o => ({
        code: slugify(o.value || o.text),
        name: o.text || o.value,
        value: o.value
      }));

    if (LIMIT_MARKETS > 0) {
      options = options.slice(0, LIMIT_MARKETS);
    }

    for (const opt of options) {
      try {
        await page.evaluate(({ idx, value, text }) => {
          const s = document.querySelectorAll('select')[idx];
          if (!s) return;

          const target = Array.from(s.options).find(o => o.value === value || o.textContent.trim() === text);
          if (target) {
            s.value = target.value;
            s.dispatchEvent(new Event('input', { bubbles: true }));
            s.dispatchEvent(new Event('change', { bubbles: true }));
          }
        }, { idx: bestSelect.idx, value: opt.value, text: opt.name });

        await page.waitForTimeout(2500);
        await page.waitForLoadState('networkidle', { timeout: 6000 }).catch(() => {});

        const html = await page.content();
        const rows = extractResultRowsFromHtml(html, {
          code: opt.code,
          name: opt.name
        });

        allRows.push(...rows);

        console.log(`Source ${opt.code}: ${rows.length} row`);
      } catch (error) {
        console.error(`Market ${opt.code} gagal: ${error.message}`);
      }
    }
  } finally {
    await browser.close();
  }

  const unique = new Map();

  for (const row of allRows) {
    unique.set(`${row.market_code}|${row.draw_date}|${row.result}`, row);
  }

  return [...unique.values()];
}

async function main() {
  const client = await pool.connect();

  let runId = null;
  let inserted = 0;
  let updated = 0;
  let unchanged = 0;
  let errors = 0;
  let totalSeen = 0;

  try {
    if (!DRY_RUN) {
      const run = await client.query(`
        INSERT INTO source_fetch_runs (source_name, source_url, status)
        VALUES ($1, $2, 'running')
        RETURNING id
      `, [SOURCE_NAME, RESULT_URL]);

      runId = run.rows[0].id;
    }

    const scheduleCount = await syncSchedules(client);
    console.log(`Schedule sync: ${scheduleCount} market`);

    const index = await loadMarketIndex(client);
    const rows = await fetchDynamicResults();

    totalSeen = rows.length;

    console.log(`Fetched rows: ${rows.length}`);

    for (const row of rows) {
      try {
        const marketCode = slugify(row.market_code || row.market_name);
        const marketName = row.market_name || marketCode;

        if (!marketCode || !row.draw_date || !row.result) {
          throw new Error('Data source tidak lengkap');
        }

        const marketId = await ensureMarket(client, index, marketCode, marketName);

        if (DRY_RUN) {
          console.log(`[DRY] ${marketCode} ${row.draw_date} ${row.result}`);
          continue;
        }

        const existing = await client.query(`
          SELECT id, result
          FROM result_draws
          WHERE market_id = $1 AND draw_date = $2
        `, [marketId, row.draw_date]);

        await client.query(`
          INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
          VALUES ($1, $2, $3, 'auto-source:${SOURCE_NAME}', $4::jsonb)
          ON CONFLICT (market_id, draw_date)
          DO UPDATE SET
            result = EXCLUDED.result,
            source = EXCLUDED.source,
            raw_payload = EXCLUDED.raw_payload,
            updated_at = NOW()
        `, [marketId, row.draw_date, row.result, JSON.stringify({
          source: SOURCE_NAME,
          source_url: RESULT_URL,
          fetched_at: DateTime.now().setZone('Asia/Jakarta').toISO(),
          raw: row.raw
        })]);

        if (existing.rowCount === 0) {
          inserted++;
        } else if (existing.rows[0].result !== row.result) {
          updated++;
        } else {
          unchanged++;
        }
      } catch (error) {
        errors++;

        if (!DRY_RUN && runId) {
          await client.query(`
            INSERT INTO source_fetch_errors (run_id, market_code, draw_date, result, error_message, raw_payload)
            VALUES ($1, $2, $3, $4, $5, $6::jsonb)
          `, [
            runId,
            row.market_code || null,
            row.draw_date || null,
            row.result || null,
            error.message,
            JSON.stringify(row)
          ]);
        }

        console.error(`Row error: ${error.message}`);
      }
    }

    if (!DRY_RUN && runId) {
      await client.query(`
        UPDATE source_fetch_runs
        SET status = $1,
            total_seen = $2,
            inserted_count = $3,
            updated_count = $4,
            unchanged_count = $5,
            error_count = $6,
            message = $7,
            finished_at = NOW()
        WHERE id = $8
      `, [
        errors > 0 ? 'completed_with_errors' : 'completed',
        totalSeen,
        inserted,
        updated,
        unchanged,
        errors,
        `Auto fetch selesai. schedule=${scheduleCount}`,
        runId
      ]);
    }

    console.log('AUTO FETCH SELESAI');
    console.log({ dry_run: DRY_RUN, totalSeen, inserted, updated, unchanged, errors });
  } catch (error) {
    if (!DRY_RUN && runId) {
      await client.query(`
        UPDATE source_fetch_runs
        SET status = 'failed',
            message = $1,
            finished_at = NOW()
        WHERE id = $2
      `, [error.message, runId]);
    }

    throw error;
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch(error => {
  console.error('AUTO FETCH GAGAL:', error.message);
  process.exit(1);
});
