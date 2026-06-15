require('dotenv').config();

const axios = require('axios');
const cheerio = require('cheerio');
const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const morgan = require('morgan');
const pg = require('pg');
pg.types.setTypeParser(1082, value => value);
const { Pool } = pg;
const { z } = require('zod');

const app = express();
const port = Number(process.env.PORT || 3001);

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000
});

const SOURCE_MARKET_URL = 'https://prediksi90.angka-alexis.pro/?page=data-keluaran-togel';
const OREGON_CANONICAL_MAP = {
  oregon3: { code: 'oregon-04-00-wib', name: 'Oregon 04:00 Wib' },
  oregon6: { code: 'oregon-07-00-wib', name: 'Oregon 07:00 Wib' },
  oregon9: { code: 'oregon-10-00-wib', name: 'Oregon 10:00 Wib' },
  oregon12: { code: 'oregon-13-00-wib', name: 'Oregon 13:00 Wib' }
};

app.use(helmet());
app.use(cors({
  origin: [
    'https://jhunaey.my.id',
    'https://www.jhunaey.my.id',
    'http://localhost:3000',
    'http://localhost:5173'
  ],
  credentials: true
}));
app.use(express.json({ limit: '5mb' }));
app.use(morgan('combined'));

function requireAdminToken(req, res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';

  if (!process.env.ADMIN_API_TOKEN || token !== process.env.ADMIN_API_TOKEN) {
    return res.status(401).json({
      ok: false,
      error: 'Unauthorized'
    });
  }

  next();
}

function normalizeMarketCode(value) {
  return String(value || '').trim().toLowerCase().replace(/[^a-z0-9:_-]/g, '-');
}

function normalizeMarketName(value, code) {
  const raw = String(value || '').replace(/\s*\[NOT-SOURCE-HIDDEN\]\s*$/i, '').trim();
  if (raw) return raw;

  return String(code || '')
    .replace(/[-_:]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/\b\w/g, c => c.toUpperCase());
}

function titleCase(value) {
  return String(value || '')
    .trim()
    .replace(/[-_]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
}

function normalizeCanonicalMarketName(value, code) {
  const raw = normalizeMarketName(value, code);
  return raw
    .replace(/^Totomacau\b/i, 'Toto Macau')
    .replace(/^Toto Macau[-_]+/i, 'Toto Macau ')
    .replace(/^Toto Macau\s*([0-9:])/i, 'Toto Macau $1')
    .replace(/\s+/g, ' ')
    .trim();
}

function resolveCanonicalMarket(sourceName, sourceValue) {
  const source_code = normalizeMarketCode(sourceValue || sourceName);
  const source_name = normalizeMarketName(sourceName, source_code);
  const source_value = String(sourceValue || '').trim() || source_code;

  if (OREGON_CANONICAL_MAP[source_code]) {
    const canonical = OREGON_CANONICAL_MAP[source_code];
    return {
      source_name,
      source_value,
      source_code,
      canonical_market_code: canonical.code,
      canonical_market_name: canonical.name,
      notes: 'explicit Oregon alias mapping'
    };
  }

  const canonical_market_code = source_code;
  const canonical_market_name = normalizeCanonicalMarketName(titleCase(source_name), source_code);

  return {
    source_name,
    source_value,
    source_code,
    canonical_market_code,
    canonical_market_name,
    notes: ''
  };
}

async function ensureMarketProfile(client, marketId) {
  await client.query(`
    INSERT INTO market_profiles (market_id)
    VALUES ($1)
    ON CONFLICT (market_id) DO NOTHING
  `, [marketId]);
}

async function ensureCanonicalMarket(client, canonicalMarket, displayOrder) {
  const result = await client.query(`
    INSERT INTO markets (code, name, timezone, is_active, display_order)
    VALUES ($1, $2, 'Asia/Jakarta', TRUE, $3)
    ON CONFLICT (code)
    DO UPDATE SET
      name = EXCLUDED.name,
      timezone = EXCLUDED.timezone,
      is_active = TRUE,
      display_order = CASE
        WHEN markets.display_order = 0 OR markets.display_order > EXCLUDED.display_order
          THEN EXCLUDED.display_order
        ELSE markets.display_order
      END,
      updated_at = NOW()
    RETURNING id
  `, [canonicalMarket.canonical_market_code, canonicalMarket.canonical_market_name, displayOrder]);

  await ensureMarketProfile(client, result.rows[0].id);
  return result.rows[0].id;
}

async function upsertMarketAlias(client, aliasRow, canonicalMarketId, sourceUrl, displayOrder) {
  await client.query(`
    INSERT INTO market_source_aliases (
      source_name,
      source_value,
      source_code,
      canonical_market_id,
      canonical_market_code,
      canonical_market_name,
      source_url,
      is_active,
      notes,
      created_at,
      updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, TRUE, $8, NOW(), NOW())
    ON CONFLICT (source_url, source_code)
    DO UPDATE SET
      source_name = EXCLUDED.source_name,
      source_value = EXCLUDED.source_value,
      canonical_market_id = EXCLUDED.canonical_market_id,
      canonical_market_code = EXCLUDED.canonical_market_code,
      canonical_market_name = EXCLUDED.canonical_market_name,
      is_active = EXCLUDED.is_active,
      notes = EXCLUDED.notes,
      updated_at = NOW()
  `, [
    aliasRow.source_name,
    aliasRow.source_value,
    aliasRow.source_code,
    canonicalMarketId,
    aliasRow.canonical_market_code,
    aliasRow.canonical_market_name,
    sourceUrl,
    aliasRow.notes || '',
    displayOrder
  ]);
}

async function fetchSourceMarketOptions(sourceUrl) {
  const response = await axios.get(sourceUrl, {
    timeout: 60000,
    maxContentLength: Infinity,
    maxBodyLength: Infinity,
    headers: {
      'User-Agent': 'Mozilla/5.0 BBFS-Shinobi-Alias-Sync/1.0',
      'Accept': 'text/html,*/*'
    }
  });

  const $ = cheerio.load(String(response.data || ''));
  const seen = new Set();
  const options = [];

  $('#selectpasaran option, select option').each((_, option) => {
    const value = String($(option).attr('value') || '').trim();
    const text = String($(option).text() || '').trim();
    if (!value) return;
    if (/^(0|select|pilih|choose)$/i.test(value)) return;
    if (/pilih\s+pasaran/i.test(text)) return;

    const source_value = value;
    const source_name = text || value;
    const source_code = normalizeMarketCode(source_value || source_name);
    const key = `${source_code}|${source_value}`;
    if (seen.has(key)) return;
    seen.add(key);

    options.push({ source_name, source_value, source_code });
  });

  if (options.length > 0) {
    return options;
  }

  const bodyText = $.text().replace(/\s+/g, ' ').trim();
  const m = bodyText.match(/Pilih Pasaran\s+(.+?)\s+Mohon ditunggu/i);
  if (!m) return [];

  for (const token of m[1].split(/\s+/).filter(Boolean)) {
    const source_value = token.trim();
    const source_code = normalizeMarketCode(source_value);
    const key = `${source_code}|${source_value}`;
    if (seen.has(key)) continue;
    seen.add(key);
    options.push({
      source_name: titleCase(source_value),
      source_value,
      source_code
    });
  }

  return options;
}

async function syncAliasesFromSource(client, sourceUrl) {
  const options = await fetchSourceMarketOptions(sourceUrl);
  const summary = {
    source_url: sourceUrl,
    source_count: options.length,
    created_canonicals: 0,
    updated_canonicals: 0,
    aliases_upserted: 0
  };

  for (let i = 0; i < options.length; i++) {
    const option = options[i];
    const resolved = resolveCanonicalMarket(option.source_name, option.source_value);
    const canonicalId = await ensureCanonicalMarket(client, resolved, i + 1);

    const canonicalResult = await client.query(`
      SELECT code, name
      FROM markets
      WHERE id = $1
    `, [canonicalId]);

    const canonicalMarket = canonicalResult.rows[0];
    const before = await client.query('SELECT id FROM market_source_aliases WHERE source_url = $1 AND source_code = $2', [sourceUrl, resolved.source_code]);

    await upsertMarketAlias(client, {
      source_name: resolved.source_name,
      source_value: resolved.source_value,
      source_code: resolved.source_code,
      canonical_market_code: canonicalMarket.code,
      canonical_market_name: canonicalMarket.name,
      notes: resolved.notes
    }, canonicalId, sourceUrl, i + 1);

    if (before.rowCount === 0) summary.aliases_upserted++;
  }

  return summary;
}

app.get('/api/health', async (req, res) => {
  try {
    const db = await pool.query('SELECT NOW() AS now');
    const counts = await pool.query(`
      SELECT
        (SELECT COUNT(*)::int FROM markets) AS markets,
        (SELECT COUNT(*)::int FROM result_draws) AS results,
        (SELECT COUNT(*)::int FROM formula_versions) AS formulas
    `);

    res.json({
      ok: true,
      service: 'bbfs-shinobi-backend',
      database: 'connected',
      time: db.rows[0].now,
      counts: counts.rows[0]
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      database: 'error',
      error: error.message
    });
  }
});

app.get('/api/markets', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT
        id,
        code,
        COALESCE(NULLIF(TRIM(name), ''), code) AS name,
        timezone,
        is_active,
        display_order
      FROM markets
      WHERE is_active = TRUE
      ORDER BY
        LOWER(COALESCE(NULLIF(TRIM(name), ''), code)) ASC,
        LOWER(code) ASC
    `);

    res.json({ ok: true, data: result.rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.get('/api/market-aliases', async (req, res) => {
  try {
    const sourceUrl = String(req.query.source_url || '').trim();
    const params = [];
    const where = sourceUrl ? 'WHERE a.source_url = $1' : '';

    if (sourceUrl) params.push(sourceUrl);

    const result = await pool.query(`
      SELECT
        a.id,
        a.source_name,
        a.source_value,
        a.source_code,
        a.canonical_market_id,
        a.canonical_market_code,
        a.canonical_market_name,
        a.source_url,
        a.is_active,
        a.notes,
        a.created_at,
        a.updated_at
      FROM market_source_aliases a
      ${where}
      ORDER BY a.canonical_market_name ASC, a.source_name ASC, a.source_code ASC
    `, params);

    res.json({ ok: true, data: result.rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.get('/api/market-aliases/conflicts', async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT
        id,
        source_name,
        source_value,
        source_code,
        canonical_market_id,
        canonical_market_code,
        canonical_market_name,
        source_url,
        draw_date,
        existing_result,
        incoming_result,
        existing_source,
        incoming_source,
        existing_market_id,
        incoming_market_id,
        notes,
        created_at
      FROM market_source_alias_conflicts
      ORDER BY draw_date DESC, created_at DESC
    `);
    res.json({ ok: true, data: result.rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/market-aliases/sync-from-source', requireAdminToken, async (req, res) => {
  const sourceUrl = String(req.body.source_url || SOURCE_MARKET_URL).trim() || SOURCE_MARKET_URL;
  const client = await pool.connect();

  try {
    await client.query('BEGIN');
    const summary = await syncAliasesFromSource(client, sourceUrl);
    await client.query('COMMIT');

    res.json({
      ok: true,
      data: summary
    });
  } catch (error) {
    await client.query('ROLLBACK');
    res.status(500).json({ ok: false, error: error.message });
  } finally {
    client.release();
  }
});

app.post('/api/markets', requireAdminToken, async (req, res) => {
  const schema = z.object({
    code: z.string().min(2).max(80),
    name: z.string().min(2).max(120),
    timezone: z.string().default('Asia/Jakarta'),
    display_order: z.number().int().default(0)
  });

  const body = schema.parse(req.body);
  const code = normalizeMarketCode(body.code);
  const name = normalizeMarketName(body.name, code);

  const result = await pool.query(`
    INSERT INTO markets (code, name, timezone, display_order)
    VALUES ($1, $2, $3, $4)
    ON CONFLICT (code)
    DO UPDATE SET
      name = EXCLUDED.name,
      timezone = EXCLUDED.timezone,
      display_order = EXCLUDED.display_order,
      updated_at = NOW()
    RETURNING *
  `, [code, name, body.timezone, body.display_order]);

  await pool.query(`
    INSERT INTO market_profiles (market_id)
    VALUES ($1)
    ON CONFLICT (market_id) DO NOTHING
  `, [result.rows[0].id]);

  await pool.query(`
    INSERT INTO sync_logs (entity, entity_id, action, status, message)
    VALUES ('market', $1, 'upsert', 'success', 'Market created or updated')
  `, [result.rows[0].id]);

  res.status(201).json({
    ok: true,
    data: result.rows[0]
  });
});

app.get('/api/results/latest', async (req, res) => {
  const limit = Math.min(Number(req.query.limit || 20), 100);
  const marketCode = req.query.market_code ? normalizeMarketCode(req.query.market_code) : null;

  const params = [];
  let where = '';

  if (marketCode) {
    params.push(marketCode);
    where = 'WHERE m.code = $1';
  }

  params.push(limit);

  const result = await pool.query(`
    SELECT
      r.id,
      m.code AS market_code,
      m.name AS market_name,
      r.draw_date,
      r.result,
      RIGHT(r.result, 4) AS result_4d,
      r.result_2d,
      r.result_3d,
      COALESCE(r.raw_payload->>'result_time', '') AS result_time,
      r.source,
      r.created_at,
      r.updated_at
    FROM result_draws r
    JOIN markets m ON m.id = r.market_id
    ${where}
    ORDER BY r.draw_date DESC, m.display_order ASC, m.name ASC
    LIMIT $${params.length}
  `, params);

  res.json({
    ok: true,
    data: result.rows
  });
});

app.post('/api/results', requireAdminToken, async (req, res) => {
  const schema = z.object({
    market_code: z.string().min(2).max(80),
    draw_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    result: z.string().regex(/^[0-9]{2,7}$/),
    source: z.string().default('manual')
  });

  const body = schema.parse(req.body);
  const marketCode = normalizeMarketCode(body.market_code);

  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    const market = await client.query(
      'SELECT id FROM markets WHERE code = $1',
      [marketCode]
    );

    if (market.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({
        ok: false,
        error: 'Market belum ada. Buat market dulu lewat POST /api/markets.'
      });
    }

    const inserted = await client.query(`
      INSERT INTO result_draws (market_id, draw_date, result, source)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (market_id, draw_date)
      DO UPDATE SET
        result = EXCLUDED.result,
        source = EXCLUDED.source,
        updated_at = NOW()
      RETURNING *
    `, [market.rows[0].id, body.draw_date, body.result, body.source]);

    await client.query(`
      INSERT INTO sync_logs (entity, entity_id, action, status, message)
      VALUES ('result_draw', $1, 'upsert', 'success', 'Result saved and ready for prediction sync')
    `, [inserted.rows[0].id]);

    await client.query('COMMIT');

    res.status(201).json({
      ok: true,
      data: inserted.rows[0],
      sync: {
        status: 'queued_later',
        note: 'Prediction engine akan dibuat pada tahap berikutnya.'
      }
    });
  } catch (error) {
    await client.query('ROLLBACK');
    res.status(500).json({
      ok: false,
      error: error.message
    });
  } finally {
    client.release();
  }
});

app.get('/api/stats/summary', async (req, res) => {
  const result = await pool.query(`
    SELECT
      (SELECT COUNT(*)::int FROM markets WHERE is_active = TRUE) AS active_markets,
      (SELECT COUNT(*)::int FROM result_draws) AS total_results,
      (SELECT MAX(draw_date) FROM result_draws) AS latest_draw_date,
      (SELECT COUNT(*)::int FROM prediction_runs) AS prediction_runs
  `);

  res.json({
    ok: true,
    data: result.rows[0]
  });
});

try { require('./manual_fetch_routes')(app, pool); console.log('Manual fetch routes enabled'); } catch (e) { console.error('Manual fetch routes failed:', e.message); }


function parseWorkerFinalJson(stdout) {
  const text = String(stdout || '').trimEnd();
  let idx = text.lastIndexOf('\n{');
  while (idx !== -1) {
    const candidate = text.slice(idx + 1).trim();
    try {
      return JSON.parse(candidate);
    } catch (_) {}
    idx = text.lastIndexOf('\n{', idx - 1);
  }
  try { return JSON.parse(text); } catch (_) {}
  return null;
}

function summarizeManualFetchResult(parsed, fallback) {
  const sample = Array.isArray(parsed?.sample) ? parsed.sample.slice(0, 20).map(row => ({
    draw_date: row.draw_date,
    result: row.result,
    result_time: row.result_time
  })) : [];

  return {
    ok: Boolean(parsed?.ok),
    status: parsed?.status || (parsed?.ok ? 'completed' : 'failed'),
    canonical_market_code: parsed?.sample?.[0]?.canonical_market_code || fallback.market || null,
    canonical_market_name: parsed?.sample?.[0]?.canonical_market_name || null,
    source_name: parsed?.sample?.[0]?.source_name || null,
    source_value: parsed?.sample?.[0]?.source_value || null,
    date_from: parsed?.date_from || fallback.dateFrom || null,
    date_to: parsed?.date_to || fallback.dateTo || null,
    inserted: Number(parsed?.inserted || 0),
    updated: Number(parsed?.updated || 0),
    unchanged: Number(parsed?.unchanged || 0),
    conflicts: Number(parsed?.conflicts || 0),
    failed: Number(parsed?.failed || 0),
    sample,
    debug_raw: parsed?.ok === false ? fallback.stdout : undefined
  };
}

// Manual fetch by selected date range
app.post('/api/manual-fetch/date-range', requireAdminToken, async (req, res) => {
  const { execFile } = require('child_process');

  const sourceUrl = String(req.body.source_url || '').trim();
  const market = String(req.body.market || '').trim();
  const dateFrom = String(req.body.date_from || '').trim();
  const dateTo = String(req.body.date_to || '').trim();

  if (!sourceUrl || !market || !dateFrom || !dateTo) {
    return res.status(400).json({
      ok: false,
      error: 'source_url, market, date_from, dan date_to wajib diisi.'
    });
  }

  const script = '/opt/bbfs-shinobi/backend/scripts/manual_fetch_date_range_worker.js';

  execFile('/usr/bin/node', [script, sourceUrl, market, dateFrom, dateTo], {
    cwd: '/opt/bbfs-shinobi/backend',
    timeout: 240000,
    maxBuffer: 1024 * 1024 * 10,
    env: {
      ...process.env,
      NODE_PATH: '/opt/bbfs-shinobi/backend/node_modules'
    }
  }, (error, stdout, stderr) => {
    const parsed = parseWorkerFinalJson(stdout);
    const payload = summarizeManualFetchResult(parsed, {
      market,
      dateFrom,
      dateTo,
      stdout: String(stdout || '').slice(0, 12000),
      stderr: String(stderr || '').slice(0, 4000)
    });

    if (error) {
      if (parsed) {
        return res.status(payload.ok ? 200 : 500).json(payload);
      }
      return res.status(500).json({
        ok: false,
        error: error.message,
        debug_raw: String(stdout || '').slice(0, 12000),
        debug_stderr: String(stderr || '').slice(0, 4000)
      });
    }

    if (parsed) {
      return res.json(payload);
    }

    res.status(502).json({
      ok: false,
      status: 'invalid_worker_output',
      error: 'Worker selesai tetapi tidak mengembalikan JSON final.',
      debug_raw: String(stdout || '').slice(0, 12000),
      debug_stderr: String(stderr || '').slice(0, 4000)
    });
  });
});

app.post('/api/manual-fetch/date-range-all', requireAdminToken, async (req, res) => {
  const fs = require('fs');
  const { spawn } = require('child_process');

  const sourceUrl = String(req.body.source_url || '').trim();
  const dateFrom = String(req.body.date_from || '').trim();
  const dateTo = String(req.body.date_to || '').trim();

  if (!sourceUrl || !dateFrom || !dateTo) {
    return res.status(400).json({
      ok: false,
      error: 'source_url, date_from, dan date_to wajib diisi.'
    });
  }

  const statusFile = '/opt/bbfs-shinobi/manual_fetch_date_status.json';
  const logFile = '/opt/bbfs-shinobi/manual_fetch_date.log';
  const script = '/opt/bbfs-shinobi/backend/scripts/manual_fetch_date_range_worker.js';

  try {
    fs.writeFileSync(logFile, '');
    fs.writeFileSync(statusFile, JSON.stringify({
      status: 'starting',
      source_url: sourceUrl,
      date_from: dateFrom,
      date_to: dateTo,
      mode: 'all',
      updated_at: new Date().toISOString()
    }, null, 2));
  } catch (_) {}

  const child = spawn('/usr/bin/node', [script, sourceUrl, '__ALL__', dateFrom, dateTo], {
    cwd: '/opt/bbfs-shinobi/backend',
    detached: true,
    stdio: ['ignore', 'ignore', 'ignore'],
    env: {
      ...process.env,
      NODE_PATH: '/opt/bbfs-shinobi/backend/node_modules',
      ALL_MARKETS: '1',
      SOURCE_URL: sourceUrl,
      DATE_FROM: dateFrom,
      DATE_TO: dateTo,
      STATUS_FILE: statusFile,
      LOG_FILE: logFile
    }
  });

  child.unref();

  res.json({
    ok: true,
    status: 'started',
    pid: child.pid,
    message: 'Fetch semua pasaran berdasarkan tanggal sudah dimulai. Tekan CEK STATUS.'
  });
});

app.get('/api/manual-fetch/date-range-status', requireAdminToken, async (req, res) => {
  const fs = require('fs');

  const statusFile = '/opt/bbfs-shinobi/manual_fetch_date_status.json';
  const logFile = '/opt/bbfs-shinobi/manual_fetch_date.log';

  let status = { status: 'not_started' };
  let logs = '';

  try {
    status = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
  } catch (_) {}

  try {
    logs = fs.readFileSync(logFile, 'utf8').split('\n').slice(-80).join('\n');
  } catch (_) {}

  res.json({
    ok: true,
    status,
    logs
  });
});



// Show all results for one selected market.
app.get('/api/manual-result/all-by-market', requireAdminToken, async (req, res) => {
  try {
    const marketCode = req.query.market_code ? normalizeMarketCode(req.query.market_code) : '';

    if (!marketCode) {
      return res.status(400).json({
        ok: false,
        error: 'market_code wajib diisi.'
      });
    }

    const result = await pool.query(`
      SELECT
        r.id,
        m.code AS market_code,
        m.name AS market_name,
        TO_CHAR(r.draw_date, 'YYYY-MM-DD') AS draw_date,
        RIGHT(r.result, 4) AS result_4d,
        r.result,
        r.result_2d,
        r.result_3d,
        COALESCE(r.raw_payload->>'result_time', '') AS result_time,
        r.source,
        r.updated_at
      FROM result_draws r
      JOIN markets m ON m.id = r.market_id
      WHERE m.code = $1
      ORDER BY r.draw_date DESC, r.updated_at DESC
    `, [marketCode]);

    res.json({
      ok: true,
      market_code: marketCode,
      total: result.rows.length,
      data: result.rows
    });
  } catch (error) {
    res.status(500).json({
      ok: false,
      error: error.message
    });
  }
});


// Manual Result CRUD: add, edit, delete, list result 4D.
app.get('/api/manual-result/list', requireAdminToken, async (req, res) => {
  try {
    const marketCode = req.query.market_code ? normalizeMarketCode(req.query.market_code) : '';
    const limit = Math.min(Math.max(Number(req.query.limit || 30), 1), 200);

    const params = [];
    let where = '';

    if (marketCode) {
      params.push(marketCode);
      where = 'WHERE m.code = $1';
    }

    params.push(limit);

    const result = await pool.query(`
      SELECT
        r.id,
        m.code AS market_code,
        m.name AS market_name,
        TO_CHAR(r.draw_date, 'YYYY-MM-DD') AS draw_date,
        RIGHT(r.result, 4) AS result_4d,
        r.result,
        r.result_2d,
        r.result_3d,
        COALESCE(r.raw_payload->>'result_time', '') AS result_time,
        r.source,
        r.updated_at
      FROM result_draws r
      JOIN markets m ON m.id = r.market_id
      ${where}
      ORDER BY r.draw_date DESC, r.updated_at DESC
      LIMIT $${params.length}
    `, params);

    res.json({ ok: true, data: result.rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/manual-result/add', requireAdminToken, async (req, res) => {
  const schema = z.object({
    market_code: z.string().min(2).max(120),
    market_name: z.string().optional().default(''),
    draw_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    result: z.string().regex(/^[0-9]{4}$/),
    result_time: z.string().optional().default('')
  });

  try {
    const body = schema.parse(req.body);
    const marketCode = normalizeMarketCode(body.market_code);
    const marketName = body.market_name || marketCode.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase());

    const client = await pool.connect();

    try {
      await client.query('BEGIN');

      const market = await client.query(`
        INSERT INTO markets (code, name, timezone, is_active, display_order)
        VALUES ($1, $2, 'Asia/Jakarta', TRUE, 999)
        ON CONFLICT (code)
        DO UPDATE SET name = COALESCE(NULLIF(markets.name, ''), EXCLUDED.name), updated_at = NOW()
        RETURNING id, code, name
      `, [marketCode, marketName]);

      await client.query(`
        INSERT INTO market_profiles (market_id)
        VALUES ($1)
        ON CONFLICT (market_id) DO NOTHING
      `, [market.rows[0].id]);

      const exists = await client.query(`
        SELECT id
        FROM result_draws
        WHERE market_id = $1 AND draw_date = $2::date
      `, [market.rows[0].id, body.draw_date]);

      if (exists.rowCount > 0) {
        await client.query('ROLLBACK');
        return res.status(409).json({
          ok: false,
          action: 'exists',
          error: 'Result untuk pasaran dan tanggal ini sudah ada. Gunakan EDIT RESULT untuk mengubah.'
        });
      }

      const inserted = await client.query(`
        INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
        VALUES (
          $1,
          $2::date,
          $3,
          'manual-add',
          jsonb_build_object(
            'result_time', $4::text,
            'raw_line', concat('MANUAL | ', to_char($2::date, 'YYYY-MM-DD'), ' | ', $3::text, ' | ', $4::text),
            'input_mode', 'manual_add'
          )
        )
        RETURNING id, draw_date, result, result_2d, result_3d, raw_payload, source, updated_at
      `, [market.rows[0].id, body.draw_date, body.result, body.result_time]);

      await client.query(`
        INSERT INTO sync_logs (entity, entity_id, action, status, message)
        VALUES ('result_draw', $1, 'manual_add', 'success', 'Manual result added')
      `, [inserted.rows[0].id]);

      await client.query('COMMIT');

      res.status(201).json({
        ok: true,
        action: 'added',
        market_code: market.rows[0].code,
        market_name: market.rows[0].name,
        draw_date: body.draw_date,
        result: body.result,
        result_time: body.result_time,
        data: inserted.rows[0]
      });
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  } catch (error) {
    if (error.name === 'ZodError') {
      return res.status(400).json({ ok: false, error: 'Validasi gagal', details: error.errors });
    }
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.put('/api/manual-result/edit', requireAdminToken, async (req, res) => {
  const schema = z.object({
    market_code: z.string().min(2).max(120),
    draw_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
    result: z.string().regex(/^[0-9]{4}$/),
    result_time: z.string().optional().default('')
  });

  try {
    const body = schema.parse(req.body);
    const marketCode = normalizeMarketCode(body.market_code);

    const client = await pool.connect();

    try {
      await client.query('BEGIN');

      const market = await client.query(`
        SELECT id, code, name
        FROM markets
        WHERE code = $1
        LIMIT 1
      `, [marketCode]);

      if (market.rowCount === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ ok: false, error: 'Pasaran tidak ditemukan.' });
      }

      const updated = await client.query(`
        UPDATE result_draws
        SET
          result = $3,
          source = 'manual-edit',
          raw_payload = raw_payload || jsonb_build_object(
            'result_time', $4::text,
            'raw_line', concat('MANUAL EDIT | ', to_char($2::date, 'YYYY-MM-DD'), ' | ', $3::text, ' | ', $4::text),
            'input_mode', 'manual_edit'
          ),
          updated_at = NOW()
        WHERE market_id = $1
          AND draw_date = $2
        RETURNING id, draw_date, result, result_2d, result_3d, raw_payload, source, updated_at
      `, [market.rows[0].id, body.draw_date, body.result, body.result_time]);

      if (updated.rowCount === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({
          ok: false,
          error: 'Result belum ada. Gunakan ADD RESULT untuk menambah data baru.'
        });
      }

      await client.query(`
        INSERT INTO sync_logs (entity, entity_id, action, status, message)
        VALUES ('result_draw', $1, 'manual_edit', 'success', 'Manual result edited')
      `, [updated.rows[0].id]);

      await client.query('COMMIT');

      res.json({
        ok: true,
        action: 'edited',
        market: market.rows[0],
        data: updated.rows[0]
      });
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  } catch (error) {
    if (error.name === 'ZodError') {
      return res.status(400).json({ ok: false, error: 'Validasi gagal', details: error.errors });
    }
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.delete('/api/manual-result/delete', requireAdminToken, async (req, res) => {
  const schema = z.object({
    market_code: z.string().min(2).max(120),
    draw_date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/)
  });

  try {
    const body = schema.parse(req.body);
    const marketCode = normalizeMarketCode(body.market_code);

    const client = await pool.connect();

    try {
      await client.query('BEGIN');

      const market = await client.query(`
        SELECT id, code, name
        FROM markets
        WHERE code = $1
        LIMIT 1
      `, [marketCode]);

      if (market.rowCount === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ ok: false, error: 'Pasaran tidak ditemukan.' });
      }

      const deleted = await client.query(`
        DELETE FROM result_draws
        WHERE market_id = $1
          AND draw_date = $2
        RETURNING id, draw_date, result, result_2d, result_3d, source, updated_at
      `, [market.rows[0].id, body.draw_date]);

      if (deleted.rowCount === 0) {
        await client.query('ROLLBACK');
        return res.status(404).json({ ok: false, error: 'Result tidak ditemukan untuk tanggal itu.' });
      }

      await client.query(`
        INSERT INTO sync_logs (entity, entity_id, action, status, message)
        VALUES ('result_draw', $1, 'manual_delete', 'success', 'Manual result deleted')
      `, [deleted.rows[0].id]);

      await client.query('COMMIT');

      res.json({
        ok: true,
        action: 'deleted',
        market: market.rows[0],
        data: deleted.rows[0]
      });
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  } catch (error) {
    if (error.name === 'ZodError') {
      return res.status(400).json({ ok: false, error: 'Validasi gagal', details: error.errors });
    }
    res.status(500).json({ ok: false, error: error.message });
  }
});


// BBFS FINAL LOCKED RULES: BBFS 7 unique digits, Poltar from BBFS only,
// 2D/3D candidate rankings from BBFS digits only, confidence, prediction gate,
// holdout penalty, overfitting guard, and next-draw evaluation.
async function ensureBbfsFinalTables() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS bbfs_final_next_draw_predictions (
      id BIGSERIAL PRIMARY KEY,
      market_id uuid NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
      next_draw_date DATE NOT NULL,
      input_limit INTEGER NOT NULL DEFAULT 60,
      formula_code TEXT NOT NULL DEFAULT 'FORMULA_V1_FINAL_LOCKED',
      source TEXT NOT NULL DEFAULT 'postgresql',
      latest_result_date DATE,
      latest_result TEXT,
      bbfs_digits TEXT NOT NULL DEFAULT '',
      excluded_digits TEXT NOT NULL DEFAULT '',
      confidence NUMERIC(5,2) NOT NULL DEFAULT 0,
      prediction_status TEXT NOT NULL DEFAULT 'BBFS_UNAVAILABLE',
      user_status TEXT NOT NULL DEFAULT 'HOLD',
      can_show_prediction BOOLEAN NOT NULL DEFAULT FALSE,
      gate_json JSONB NOT NULL DEFAULT '{}'::jsonb,
      poltar_json JSONB NOT NULL DEFAULT '{}'::jsonb,
      ranking_2d_json JSONB NOT NULL DEFAULT '[]'::jsonb,
      ranking_3d_json JSONB NOT NULL DEFAULT '[]'::jsonb,
      evaluation_json JSONB NOT NULL DEFAULT '{}'::jsonb,
      payload JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE (market_id, next_draw_date)
    )
  `);

  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_bbfs_final_next_draw_market_date
    ON bbfs_final_next_draw_predictions (market_id, next_draw_date DESC)
  `);

  await pool.query(`
    CREATE INDEX IF NOT EXISTS idx_bbfs_final_next_draw_status
    ON bbfs_final_next_draw_predictions (prediction_status, can_show_prediction)
  `);
}

function finalDateJakarta() {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Jakarta',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit'
  }).format(new Date());
}

function finalDayDiffJakarta(dateText) {
  const a = new Date(String(dateText).slice(0, 10) + 'T00:00:00Z');
  const b = new Date(finalDateJakarta() + 'T00:00:00Z');
  return Math.max(0, Math.round((b - a) / 86400000));
}

function finalNextDate(dateText) {
  const d = new Date(String(dateText).slice(0, 10) + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}

function finalDigitsOnly(value) {
  return String(value || '').replace(/\D/g, '');
}

function finalPad4(value) {
  return finalDigitsOnly(value).slice(-4).padStart(4, '0');
}

function finalUniqueDigits(value) {
  const out = [];
  for (const d of String(value || '')) {
    if (/^[0-9]$/.test(d) && !out.includes(d)) out.push(d);
  }
  return out;
}

function finalBuildScoring(draws) {
  const weights = {
    frequency: 20,
    poltar_position: 20,
    trend_recent: 15,
    ranking_2d: 10,
    ranking_3d: 10,
    gap_rebound: 10,
    twin: 5,
    miss: 5,
    san: 5
  };

  const digits = '0123456789'.split('');
  const digitStats = {};
  const posStats = [
    Object.fromEntries(digits.map(d => [d, 0])),
    Object.fromEntries(digits.map(d => [d, 0])),
    Object.fromEntries(digits.map(d => [d, 0])),
    Object.fromEntries(digits.map(d => [d, 0]))
  ];

  const hist2d = {};
  const hist3d = {};

  for (const d of digits) {
    digitStats[d] = {
      digit: d,
      frequency_count: 0,
      recent_score: 0,
      position_score: 0,
      ranking_2d_score: 0,
      ranking_3d_score: 0,
      gap_score: 0,
      twin_score: 0,
      miss_score: 0,
      san_score: 0,
      last_seen_index: null
    };
  }

  draws.forEach((draw, index) => {
    const recentWeight = (draws.length - index) / draws.length;
    const r4 = draw.result_4d;
    const r2 = r4.slice(-2);
    const r3 = r4.slice(-3);

    hist2d[r2] = (hist2d[r2] || 0) + recentWeight;
    hist3d[r3] = (hist3d[r3] || 0) + recentWeight;

    draw.digits.forEach((d, pos) => {
      digitStats[d].frequency_count += 1;
      digitStats[d].recent_score += recentWeight;
      posStats[pos][d] += recentWeight;

      if (digitStats[d].last_seen_index === null) {
        digitStats[d].last_seen_index = index;
      }
    });

    r2.split('').forEach(d => digitStats[d].ranking_2d_score += recentWeight);
    r3.split('').forEach(d => digitStats[d].ranking_3d_score += recentWeight);

    const unique = new Set(draw.digits);
    if (unique.size < 4) {
      for (const d of unique) {
        if (draw.digits.filter(x => x === d).length >= 2) {
          digitStats[d].twin_score += recentWeight;
        }
      }
    }
  });

  for (const d of digits) {
    digitStats[d].position_score =
      posStats[0][d] + posStats[1][d] + posStats[2][d] + posStats[3][d];

    const last = digitStats[d].last_seen_index;
    digitStats[d].gap_score = last === null ? draws.length : Math.min(last, 25);

    const recent10 = draws.slice(0, 10).some(x => x.digits.includes(d));
    digitStats[d].miss_score = recent10 ? 0 : 1;

    const recent3 = draws.slice(0, 3).some(x => x.digits.includes(d));
    digitStats[d].san_score = recent3 ? 1 : 0;
  }

  const max = arr => Math.max(...arr, 1);
  const maxFreq = max(digits.map(d => digitStats[d].frequency_count));
  const maxRecent = max(digits.map(d => digitStats[d].recent_score));
  const maxPos = max(digits.map(d => digitStats[d].position_score));
  const maxR2 = max(digits.map(d => digitStats[d].ranking_2d_score));
  const maxR3 = max(digits.map(d => digitStats[d].ranking_3d_score));
  const maxGap = max(digits.map(d => digitStats[d].gap_score));
  const maxTwin = max(digits.map(d => digitStats[d].twin_score));
  const maxMiss = max(digits.map(d => digitStats[d].miss_score));
  const maxSan = max(digits.map(d => digitStats[d].san_score));

  const scoredDigits = digits.map(d => {
    const x = digitStats[d];

    const total =
      (x.frequency_count / maxFreq) * weights.frequency +
      (x.position_score / maxPos) * weights.poltar_position +
      (x.recent_score / maxRecent) * weights.trend_recent +
      (x.ranking_2d_score / maxR2) * weights.ranking_2d +
      (x.ranking_3d_score / maxR3) * weights.ranking_3d +
      (x.gap_score / maxGap) * weights.gap_rebound +
      (x.twin_score / maxTwin) * weights.twin +
      (x.miss_score / maxMiss) * weights.miss +
      (x.san_score / maxSan) * weights.san;

    return {
      digit: d,
      frequency_count: x.frequency_count,
      recent_score: Number(x.recent_score.toFixed(4)),
      position_score: Number(x.position_score.toFixed(4)),
      ranking_2d_score: Number(x.ranking_2d_score.toFixed(4)),
      ranking_3d_score: Number(x.ranking_3d_score.toFixed(4)),
      gap_score: Number(x.gap_score.toFixed(4)),
      twin_score: Number(x.twin_score.toFixed(4)),
      miss_score: Number(x.miss_score.toFixed(4)),
      san_score: Number(x.san_score.toFixed(4)),
      total_score: Number(total.toFixed(4))
    };
  }).sort((a, b) => b.total_score - a.total_score || a.digit.localeCompare(b.digit));

  const bbfsDigits = scoredDigits.slice(0, 7).map(x => x.digit).join('');
  const excludedDigits = digits.filter(d => !bbfsDigits.includes(d)).join('');
  const scoreMap = Object.fromEntries(scoredDigits.map(x => [x.digit, x.total_score]));

  function positionScore(pos, d) {
    return Number((posStats[pos][d] || 0).toFixed(4));
  }

  function topPositionFromBbfs(pos) {
    return bbfsDigits.split('')
      .map(d => ({ digit: d, score: positionScore(pos, d) }))
      .sort((a, b) => b.score - a.score || a.digit.localeCompare(b.digit))[0];
  }

  function rank2DFromBbfs() {
    const arr = [];

    for (const kepala of bbfsDigits) {
      for (const ekor of bbfsDigits) {
        const number = kepala + ekor;
        const historical = hist2d[number] || 0;

        const score =
          (scoreMap[kepala] || 0) * 0.32 +
          (scoreMap[ekor] || 0) * 0.38 +
          positionScore(2, kepala) * 6 +
          positionScore(3, ekor) * 7 +
          historical * 10;

        arr.push({
          number,
          kepala,
          ekor,
          count_score: Number(historical.toFixed(4)),
          score: Number(score.toFixed(4)),
          source_rule: 'BBFS_ONLY'
        });
      }
    }

    return arr
      .sort((a, b) => b.score - a.score || a.number.localeCompare(b.number))
      .map((x, i) => ({ rank: i + 1, ...x }));
  }

  function rank3DFromBbfs() {
    const arr = [];

    for (const kop of bbfsDigits) {
      for (const kepala of bbfsDigits) {
        for (const ekor of bbfsDigits) {
          const number = kop + kepala + ekor;
          const historical = hist3d[number] || 0;

          const score =
            (scoreMap[kop] || 0) * 0.25 +
            (scoreMap[kepala] || 0) * 0.31 +
            (scoreMap[ekor] || 0) * 0.34 +
            positionScore(1, kop) * 5 +
            positionScore(2, kepala) * 6 +
            positionScore(3, ekor) * 7 +
            historical * 12;

          arr.push({
            number,
            kop,
            kepala,
            ekor,
            count_score: Number(historical.toFixed(4)),
            score: Number(score.toFixed(4)),
            source_rule: 'BBFS_ONLY'
          });
        }
      }
    }

    return arr
      .sort((a, b) => b.score - a.score || a.number.localeCompare(b.number))
      .map((x, i) => ({ rank: i + 1, ...x }));
  }

  const ranking2d = rank2DFromBbfs();
  const ranking3d = rank3DFromBbfs();

  return {
    weights,
    scoredDigits,
    bbfsDigits,
    excludedDigits,
    posStats,
    poltar: {
      as: topPositionFromBbfs(0),
      kop: topPositionFromBbfs(1),
      kepala: topPositionFromBbfs(2),
      ekor: topPositionFromBbfs(3),
      source_rule: 'POLTAR_DIGITS_MUST_BE_IN_BBFS'
    },
    ranking2d,
    ranking3d,
    twin: {
      detected_digits: scoredDigits.filter(x => x.twin_score > 0 && bbfsDigits.includes(x.digit)).slice(0, 5).map(x => x.digit)
    },
    miss: {
      digits: scoredDigits.filter(x => x.miss_score > 0 && bbfsDigits.includes(x.digit)).map(x => x.digit)
    },
    san: {
      top_digits: scoredDigits.filter(x => bbfsDigits.includes(x.digit)).slice(0, 3).map(x => x.digit)
    }
  };
}

function finalEvaluateCoverage(draws, bbfsDigits) {
  const set = new Set(bbfsDigits.split(''));
  const sample = draws.length;
  let hit4d = 0;
  let hit3d = 0;
  let hit2d = 0;

  for (const draw of draws) {
    const r4 = draw.result_4d;
    const r3 = r4.slice(-3);
    const r2 = r4.slice(-2);

    if (r4.split('').every(d => set.has(d))) hit4d += 1;
    if (r3.split('').every(d => set.has(d))) hit3d += 1;
    if (r2.split('').every(d => set.has(d))) hit2d += 1;
  }

  return {
    samples: sample,
    bbfs_4d_hits: hit4d,
    bbfs_3d_hits: hit3d,
    bbfs_2d_hits: hit2d,
    bbfs_4d_rate: sample ? Number((hit4d / sample).toFixed(4)) : 0,
    bbfs_3d_rate: sample ? Number((hit3d / sample).toFixed(4)) : 0,
    bbfs_2d_rate: sample ? Number((hit2d / sample).toFixed(4)) : 0
  };
}

function finalHoldoutAudit(draws) {
  if (draws.length < 20) {
    return {
      samples: 0,
      status: 'SKIPPED_INSUFFICIENT_DATA',
      baseline_random: { bbfs_4d_rate: 0.2401, bbfs_3d_rate: 0.343, bbfs_2d_rate: 0.49 }
    };
  }

  const holdoutCount = Math.min(10, Math.max(5, Math.floor(draws.length * 0.2)));
  const holdout = draws.slice(0, holdoutCount);
  const training = draws.slice(holdoutCount);

  if (training.length < 10) {
    return {
      samples: 0,
      status: 'SKIPPED_TRAINING_TOO_SMALL',
      baseline_random: { bbfs_4d_rate: 0.2401, bbfs_3d_rate: 0.343, bbfs_2d_rate: 0.49 }
    };
  }

  const trainScore = finalBuildScoring(training);
  const coverage = finalEvaluateCoverage(holdout, trainScore.bbfsDigits);

  const baseline = {
    bbfs_4d_rate: 0.2401,
    bbfs_3d_rate: 0.343,
    bbfs_2d_rate: 0.49
  };

  return {
    status: 'DONE',
    training_samples: training.length,
    predicted_bbfs_from_training: trainScore.bbfsDigits,
    baseline_random: baseline,
    baseline_pass: {
      bbfs_4d: coverage.bbfs_4d_rate >= baseline.bbfs_4d_rate,
      bbfs_3d: coverage.bbfs_3d_rate >= baseline.bbfs_3d_rate,
      bbfs_2d: coverage.bbfs_2d_rate >= baseline.bbfs_2d_rate
    },
    ...coverage
  };
}

function finalGate(draws, latestDrawDate, score, holdout) {
  const warnings = [];
  const errors = [];

  const freshDays = finalDayDiffJakarta(latestDrawDate);
  const scoreGap = Number(((score.scoredDigits[6]?.total_score || 0) - (score.scoredDigits[7]?.total_score || 0)).toFixed(4));
  const topConcentration = Number((score.scoredDigits.slice(0, 3).reduce((a, b) => a + b.total_score, 0) / Math.max(score.scoredDigits.reduce((a, b) => a + b.total_score, 0), 1)).toFixed(4));

  if (draws.length < 5) errors.push('BBFS_FAILED: result valid kurang dari 5.');
  if (draws.length < 20) warnings.push('DATA_WARNING: data kurang dari 20 result valid.');
  if (freshDays > 14) errors.push('BBFS_BLOCKED_BY_DATA_CUTOFF: latest result lebih dari 14 hari.');
  if (!/^[0-9]{7}$/.test(score.bbfsDigits) || finalUniqueDigits(score.bbfsDigits).length !== 7) {
    errors.push('BBFS_BLOCKED_BY_SCHEMA_ERROR: BBFS bukan 7 digit unik.');
  }

  const poltarDigits = [
    score.poltar.as?.digit,
    score.poltar.kop?.digit,
    score.poltar.kepala?.digit,
    score.poltar.ekor?.digit
  ];

  if (!poltarDigits.every(d => d && score.bbfsDigits.includes(d))) {
    errors.push('BBFS_BLOCKED_BY_SCHEMA_ERROR: Poltar keluar dari digit BBFS.');
  }

  const invalid2d = score.ranking2d.slice(0, 49).find(x => !x.number.split('').every(d => score.bbfsDigits.includes(d)));
  const invalid3d = score.ranking3d.slice(0, 343).find(x => !x.number.split('').every(d => score.bbfsDigits.includes(d)));

  if (invalid2d || invalid3d) {
    errors.push('BBFS_BLOCKED_BY_SCHEMA_ERROR: Ranking 2D/3D keluar dari digit BBFS.');
  }

  if (draws.length < 40) warnings.push('DATA_WARNING: data kurang dari 40 result.');
  if (freshDays > 3 && freshDays <= 14) warnings.push('FRESHNESS_WARNING: latest result lebih dari 3 hari.');
  if (scoreGap < 1.5) warnings.push('STABILITY_WARNING: jarak skor digit ke-7 dan ke-8 terlalu tipis.');
  if (topConcentration > 0.43) warnings.push('OVERFITTING_WARNING: skor terlalu terkonsentrasi pada top digit.');

  if (holdout.status === 'DONE') {
    if (!holdout.baseline_pass.bbfs_2d && !holdout.baseline_pass.bbfs_3d) {
      warnings.push('BASELINE_WARNING: holdout 2D/3D belum mengalahkan baseline random.');
    }

    if (holdout.bbfs_2d_rate < 0.35 && holdout.bbfs_3d_rate < 0.20) {
      warnings.push('PREDICTION_GATE_WARNING: holdout 2D/3D rendah, tampilkan sebagai WASPADA.');
    }

    if (holdout.bbfs_4d_rate < 0.20) {
      warnings.push('HOLDOUT_WARNING: coverage BBFS 4D rendah.');
    }
  } else {
    warnings.push('HOLDOUT_WARNING: holdout belum cukup untuk validasi kuat.');
  }

  let predictionStatus = 'BBFS_READY';
  let userStatus = 'AMAN';
  let canShow = true;

  if (errors.some(x => x.includes('SCHEMA_ERROR'))) {
    predictionStatus = 'BBFS_BLOCKED_BY_SCHEMA_ERROR';
    userStatus = 'HOLD';
    canShow = false;
  } else if (errors.some(x => x.includes('DATA_CUTOFF'))) {
    predictionStatus = 'BBFS_BLOCKED_BY_DATA_CUTOFF';
    userStatus = 'HOLD';
    canShow = false;
  } else if (errors.some(x => x.includes('PREDICTION_GATE'))) {
    predictionStatus = 'BBFS_BLOCKED_BY_PREDICTION_GATE';
    userStatus = 'HOLD';
    canShow = false;
  } else if (errors.some(x => x.includes('INCOMPLETE'))) {
    predictionStatus = 'BBFS_INCOMPLETE';
    userStatus = 'HOLD';
    canShow = false;
  } else if (errors.length > 0) {
    predictionStatus = 'BBFS_FAILED';
    userStatus = 'HOLD';
    canShow = false;
  } else if (warnings.length > 0) {
    predictionStatus = 'BBFS_READY_WITH_WARNING';
    userStatus = 'WASPADA';
    canShow = true;
  }

  const dataScore = Math.min(20, (draws.length / 100) * 20);
  const freshnessScore = Math.max(0, 20 - freshDays * 2);
  const holdoutScore = holdout.status === 'DONE'
    ? holdout.bbfs_4d_rate * 25 + holdout.bbfs_3d_rate * 15 + holdout.bbfs_2d_rate * 10
    : 5;
  const stabilityScore = Math.max(0, Math.min(20, scoreGap * 5));

  let confidence = dataScore + freshnessScore + holdoutScore + stabilityScore;

  if (holdout.status === 'DONE' && !holdout.baseline_pass.bbfs_2d && !holdout.baseline_pass.bbfs_3d) {
    confidence -= 12;
  }

  if (topConcentration > 0.43) confidence -= 8;
  if (draws.length < 40) confidence -= 6;
  if (!canShow) confidence = Math.min(confidence, 20);
  if (predictionStatus === 'BBFS_READY_WITH_WARNING') confidence = Math.min(confidence, 65);
  if (predictionStatus === 'BBFS_READY') confidence = Math.min(confidence, 88);

  confidence = Number(Math.max(0, Math.min(99, confidence)).toFixed(2));

  // Gate V2 Final:
  // HOLD hanya untuk error fatal.
  // Warning tidak mengunci BBFS.
  // AMAN jika confidence >= 45, selain itu WASPADA.
  if (canShow) {
    if (confidence >= 45) {
      predictionStatus = 'BBFS_READY';
      userStatus = 'AMAN';
    } else {
      predictionStatus = 'BBFS_READY_WITH_WARNING';
      userStatus = 'WASPADA';
    }
  }

  return {
    prediction_status: predictionStatus,
    user_status: userStatus,
    can_show_prediction: canShow,
    confidence,
    data_cutoff: {
      latest_result_date: latestDrawDate,
      jakarta_today: finalDateJakarta(),
      freshness_days: freshDays,
      max_allowed_days: 14
    },
    holdout,
    overfitting_guard: {
      score_gap_digit_7_vs_8: scoreGap,
      top3_score_concentration: topConcentration,
      risk: topConcentration > 0.43 || scoreGap < 1.5 ? 'MEDIUM_OR_HIGH' : 'LOW'
    },
    prediction_gate: {
      errors,
      warnings,
      rule: 'BBFS tampil jika tidak ada error fatal; warning hanya mengubah status AMAN/WASPADA.'
    },
    confidence_calibration: {
      value: confidence,
      cap_rule: predictionStatus === 'BBFS_READY_WITH_WARNING'
        ? 'CAPPED_65_WARNING'
        : (!canShow ? 'CAPPED_20_BLOCKED' : 'CAPPED_88_READY')
    }
  };
}

async function finalGeneratePrediction(marketCodeInput, inputLimit, forcedNextDate) {
  await ensureBbfsFinalTables();

  const marketCode = normalizeMarketCode(marketCodeInput || '');
  const limit = Math.min(Math.max(Number(inputLimit || 60), 10), 500);

  if (!marketCode) {
    const err = new Error('market_code wajib diisi.');
    err.status = 400;
    throw err;
  }

  const marketResult = await pool.query(`
    SELECT id, code, name
    FROM markets
    WHERE code = $1 AND is_active = TRUE
    LIMIT 1
  `, [marketCode]);

  if (marketResult.rowCount === 0) {
    const err = new Error('Pasaran tidak ditemukan.');
    err.status = 404;
    throw err;
  }

  const market = marketResult.rows[0];

  const drawResult = await pool.query(`
    SELECT
      id,
      TO_CHAR(draw_date, 'YYYY-MM-DD') AS draw_date,
      RIGHT(result, 4) AS result_4d,
      RIGHT(result, 3) AS result_3d,
      RIGHT(result, 2) AS result_2d,
      COALESCE(raw_payload->>'result_time', '') AS result_time,
      raw_payload,
      updated_at
    FROM result_draws
    WHERE market_id = $1
      AND result ~ '^[0-9]{4}$'
    ORDER BY draw_date DESC
    LIMIT $2
  `, [market.id, limit]);

  const draws = drawResult.rows.map((row, index) => {
    const r4 = finalPad4(row.result_4d);
    return {
      ...row,
      index,
      result_4d: r4,
      result_3d: r4.slice(-3),
      result_2d: r4.slice(-2),
      digits: r4.split('')
    };
  }).filter(x => /^[0-9]{4}$/.test(x.result_4d));

  if (draws.length < 5) {
    const err = new Error('Data result belum cukup. Minimal 5 result valid 4D.');
    err.status = 400;
    throw err;
  }

  const latest = draws[0];
  const nextDrawDate = forcedNextDate && /^\d{4}-\d{2}-\d{2}$/.test(String(forcedNextDate))
    ? String(forcedNextDate)
    : finalNextDate(latest.draw_date);

  const score = finalBuildScoring(draws);
  const holdout = finalHoldoutAudit(draws);
  const gate = finalGate(draws, latest.draw_date, score, holdout);

  const payload = {
    source: 'postgresql',
    formula: 'FORMULA_V1_FINAL_LOCKED',
    mode: 'BBFS_AUTOMATIC_NEXT_DRAW_FINAL',
    locked_rules: {
      bbfs: '7 digit unik; 3 digit lain menjadi buangan.',
      poltar: 'AS/KOP/KEPALA/EKOR wajib dari digit BBFS.',
      target_3d: 'KOP-KEPALA-EKOR; kandidat ranking hanya dari digit BBFS.',
      target_2d: 'KEPALA-EKOR; kandidat ranking hanya dari digit BBFS.',
      data_source: 'PostgreSQL result_draws, result valid 4D Prize 1.',
      display_gate: 'Frontend menampilkan BBFS jika tidak ada error fatal; warning hanya memberi status AMAN/WASPADA.'
    },
    market,
    input_limit: draws.length,
    next_draw_date: nextDrawDate,
    based_on_latest_result: {
      draw_date: latest.draw_date,
      result: latest.result_4d,
      result_2d: latest.result_2d,
      result_3d: latest.result_3d,
      result_time: latest.result_time,
      raw_line: latest.raw_payload?.raw_line || ''
    },
    bbfs: {
      digits: gate.can_show_prediction ? score.bbfsDigits : '',
      audit_digits: score.bbfsDigits,
      excluded_digits: gate.can_show_prediction ? score.excludedDigits : '',
      audit_excluded_digits: score.excludedDigits,
      digit_scores: score.scoredDigits
    },
    poltar: gate.can_show_prediction ? score.poltar : {},
    audit_poltar: score.poltar,
    ranking_2d: gate.can_show_prediction ? score.ranking2d.slice(0, 20) : [],
    audit_ranking_2d: score.ranking2d.slice(0, 49),
    ranking_3d: gate.can_show_prediction ? score.ranking3d.slice(0, 20) : [],
    audit_ranking_3d: score.ranking3d.slice(0, 343),
    twin: {
      detected_digits: score.twin.detected_digits,
      note: 'Twin dihitung dari result historis per pasaran dan dibatasi ke digit BBFS.'
    },
    miss: {
      digits: score.miss.digits,
      note: 'Miss dihitung dari result historis per pasaran dan dibatasi ke digit BBFS.'
    },
    san: {
      top_digits: score.san.top_digits,
      note: 'San V1 awal berbasis 3 digit skor tertinggi di dalam BBFS.'
    },
    gate
  };

  const saved = await pool.query(`
    INSERT INTO bbfs_final_next_draw_predictions (
      market_id,
      next_draw_date,
      input_limit,
      formula_code,
      source,
      latest_result_date,
      latest_result,
      bbfs_digits,
      excluded_digits,
      confidence,
      prediction_status,
      user_status,
      can_show_prediction,
      gate_json,
      poltar_json,
      ranking_2d_json,
      ranking_3d_json,
      evaluation_json,
      payload
    )
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14::jsonb,$15::jsonb,$16::jsonb,$17::jsonb,$18::jsonb,$19::jsonb)
    ON CONFLICT (market_id, next_draw_date)
    DO UPDATE SET
      input_limit = EXCLUDED.input_limit,
      formula_code = EXCLUDED.formula_code,
      source = EXCLUDED.source,
      latest_result_date = EXCLUDED.latest_result_date,
      latest_result = EXCLUDED.latest_result,
      bbfs_digits = EXCLUDED.bbfs_digits,
      excluded_digits = EXCLUDED.excluded_digits,
      confidence = EXCLUDED.confidence,
      prediction_status = EXCLUDED.prediction_status,
      user_status = EXCLUDED.user_status,
      can_show_prediction = EXCLUDED.can_show_prediction,
      gate_json = EXCLUDED.gate_json,
      poltar_json = EXCLUDED.poltar_json,
      ranking_2d_json = EXCLUDED.ranking_2d_json,
      ranking_3d_json = EXCLUDED.ranking_3d_json,
      payload = EXCLUDED.payload,
      updated_at = NOW()
    RETURNING id, created_at, updated_at
  `, [
    market.id,
    nextDrawDate,
    draws.length,
    payload.formula,
    payload.source,
    latest.draw_date,
    latest.result_4d,
    gate.can_show_prediction ? score.bbfsDigits : '',
    gate.can_show_prediction ? score.excludedDigits : '',
    gate.confidence,
    gate.prediction_status,
    gate.user_status,
    gate.can_show_prediction,
    JSON.stringify(gate),
    JSON.stringify(payload.poltar),
    JSON.stringify(payload.ranking_2d),
    JSON.stringify(payload.ranking_3d),
    JSON.stringify({ status: 'WAITING_RESULT' }),
    JSON.stringify(payload)
  ]);

  return {
    id: saved.rows[0].id,
    created_at: saved.rows[0].created_at,
    updated_at: saved.rows[0].updated_at,
    ...payload
  };
}

async function finalEvaluatePredictions(marketCodeInput) {
  await ensureBbfsFinalTables();

  const params = [];
  let where = "WHERE TRUE";

  if (marketCodeInput) {
    params.push(normalizeMarketCode(marketCodeInput));
    where += ` AND m.code = $${params.length}`;
  }

  const predictions = await pool.query(`
    SELECT
      p.id,
      p.market_id,
      m.code AS market_code,
      m.name AS market_name,
      TO_CHAR(p.next_draw_date, 'YYYY-MM-DD') AS next_draw_date,
      p.bbfs_digits,
      p.poltar_json,
      p.ranking_2d_json,
      p.ranking_3d_json,
      p.can_show_prediction
    FROM bbfs_final_next_draw_predictions p
    JOIN markets m ON m.id = p.market_id
    ${where}
    ORDER BY p.next_draw_date DESC
    LIMIT 500
  `, params);

  const evaluated = [];
  const waiting = [];

  for (const pred of predictions.rows) {
    const actual = await pool.query(`
      SELECT
        TO_CHAR(draw_date, 'YYYY-MM-DD') AS draw_date,
        RIGHT(result, 4) AS result_4d,
        RIGHT(result, 3) AS result_3d,
        RIGHT(result, 2) AS result_2d,
        COALESCE(raw_payload->>'result_time', '') AS result_time
      FROM result_draws
      WHERE market_id = $1
        AND draw_date = $2
        AND result ~ '^[0-9]{4}$'
      LIMIT 1
    `, [pred.market_id, pred.next_draw_date]);

    if (actual.rowCount === 0) {
      waiting.push({
        id: pred.id,
        market_code: pred.market_code,
        market_name: pred.market_name,
        next_draw_date: pred.next_draw_date,
        status: 'WAITING_RESULT'
      });
      continue;
    }

    const row = actual.rows[0];
    const r4 = finalPad4(row.result_4d);
    const r3 = r4.slice(-3);
    const r2 = r4.slice(-2);
    const bbfsSet = new Set(String(pred.bbfs_digits || '').split(''));
    const poltar = pred.poltar_json || {};
    const rank2 = Array.isArray(pred.ranking_2d_json) ? pred.ranking_2d_json : [];
    const rank3 = Array.isArray(pred.ranking_3d_json) ? pred.ranking_3d_json : [];

    const bbfsHit = pred.can_show_prediction && r4.split('').every(d => bbfsSet.has(d));
    const hit2dRank = rank2.find(x => x.number === r2)?.rank || null;
    const hit3dRank = rank3.find(x => x.number === r3)?.rank || null;

    const poltarHit = {
      as: poltar.as?.digit === r4[0],
      kop: poltar.kop?.digit === r4[1],
      kepala: poltar.kepala?.digit === r4[2],
      ekor: poltar.ekor?.digit === r4[3]
    };

    const evaluation = {
      status: 'EVALUATED',
      market_code: pred.market_code,
      market_name: pred.market_name,
      next_draw_date: pred.next_draw_date,
      actual_result: r4,
      actual_3d: r3,
      actual_2d: r2,
      result_time: row.result_time,
      can_show_prediction: pred.can_show_prediction,
      bbfs_hit: bbfsHit,
      hit_2d: hit2dRank !== null,
      hit_2d_rank: hit2dRank,
      hit_3d: hit3dRank !== null,
      hit_3d_rank: hit3dRank,
      poltar_hit,
      poltar_hit_count: Object.values(poltarHit).filter(Boolean).length,
      evaluated_at: new Date().toISOString()
    };

    await pool.query(`
      UPDATE bbfs_final_next_draw_predictions
      SET evaluation_json = $2::jsonb, updated_at = NOW()
      WHERE id = $1
    `, [pred.id, JSON.stringify(evaluation)]);

    evaluated.push(evaluation);
  }

  return {
    evaluated_count: evaluated.length,
    waiting_count: waiting.length,
    evaluated,
    waiting
  };
}

app.post('/api/bbfs/final/generate', requireAdminToken, async (req, res) => {
  try {
    const data = await finalGeneratePrediction(
      req.body.market_code || req.query.market_code,
      req.body.limit || req.query.limit || 60,
      req.body.next_draw_date || req.query.next_draw_date || ''
    );
    res.json({ ok: true, data });
  } catch (error) {
    res.status(error.status || 500).json({ ok: false, error: error.message });
  }
});

app.post('/api/bbfs/final/generate-all', requireAdminToken, async (req, res) => {
  try {
    const limit = Math.min(Math.max(Number(req.body.limit || req.query.limit || 60), 10), 500);

    const markets = await pool.query(`
      SELECT code, name
      FROM markets
      WHERE is_active = TRUE
      ORDER BY name ASC
    `);

    const data = [];
    const errors = [];

    for (const market of markets.rows) {
      try {
        const prediction = await finalGeneratePrediction(market.code, limit, '');
        data.push({
          market_code: market.code,
          market_name: market.name,
          next_draw_date: prediction.next_draw_date,
          prediction_status: prediction.gate.prediction_status,
          user_status: prediction.gate.user_status,
          can_show_prediction: prediction.gate.can_show_prediction,
          confidence: prediction.gate.confidence,
          bbfs: prediction.bbfs.digits || prediction.bbfs.audit_digits
        });
      } catch (error) {
        errors.push({
          market_code: market.code,
          market_name: market.name,
          error: error.message
        });
      }
    }

    res.json({
      ok: true,
      total_success: data.length,
      total_error: errors.length,
      data,
      errors
    });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.get('/api/bbfs/final/latest', async (req, res) => {
  try {
    await ensureBbfsFinalTables();

    const marketCode = req.query.market_code ? normalizeMarketCode(req.query.market_code) : '';
    const limit = Math.min(Math.max(Number(req.query.limit || 20), 1), 100);

    const params = [];
    let where = '';

    if (marketCode) {
      params.push(marketCode);
      where = 'WHERE m.code = $1';
    }

    params.push(limit);

    const result = await pool.query(`
      SELECT
        p.id,
        m.code AS market_code,
        m.name AS market_name,
        TO_CHAR(p.next_draw_date, 'YYYY-MM-DD') AS next_draw_date,
        TO_CHAR(p.latest_result_date, 'YYYY-MM-DD') AS latest_result_date,
        p.latest_result,
        p.bbfs_digits,
        p.excluded_digits,
        p.confidence,
        p.prediction_status,
        p.user_status,
        p.can_show_prediction,
        p.gate_json,
        p.poltar_json,
        p.ranking_2d_json,
        p.ranking_3d_json,
        p.evaluation_json,
        p.payload,
        p.created_at,
        p.updated_at
      FROM bbfs_final_next_draw_predictions p
      JOIN markets m ON m.id = p.market_id
      ${where}
      ORDER BY p.next_draw_date DESC, p.updated_at DESC
      LIMIT $${params.length}
    `, params);

    res.json({ ok: true, data: result.rows });
  } catch (error) {
    res.status(500).json({ ok: false, error: error.message });
  }
});

app.post('/api/bbfs/final/evaluate', requireAdminToken, async (req, res) => {
  try {
    const data = await finalEvaluatePredictions(req.body.market_code || req.query.market_code || '');
    res.json({ ok: true, data });
  } catch (error) {
    res.status(error.status || 500).json({ ok: false, error: error.message });
  }
});


// Public dashboard endpoint: auto generate BBFS Final Next Draw per selected market.
// Used by index/homepage live BBFS, Ranking 2D, Ranking 3D, and recommendation table.
app.get('/api/public/bbfs-final-dashboard', async (req, res) => {
  try {
    let marketCode = req.query.market_code ? normalizeMarketCode(req.query.market_code) : '';
    const limit = Math.min(Math.max(Number(req.query.limit || 60), 10), 500);

    if (!marketCode) {
      const fallback = await pool.query(`
        SELECT m.code
        FROM result_draws r
        JOIN markets m ON m.id = r.market_id
        WHERE m.is_active = TRUE
          AND r.result ~ '^[0-9]{4}$'
        ORDER BY r.draw_date DESC, r.updated_at DESC
        LIMIT 1
      `);

      if (fallback.rowCount === 0) {
        return res.status(404).json({
          ok: false,
          error: 'Belum ada result valid untuk hitung BBFS.'
        });
      }

      marketCode = fallback.rows[0].code;
    }

    const data = await finalGeneratePrediction(marketCode, limit, '');

    res.json({
      ok: true,
      data
    });
  } catch (error) {
    res.status(error.status || 500).json({
      ok: false,
      error: error.message
    });
  }
});

app.use((err, req, res, next) => {
  if (err && err.name === 'ZodError') {
    return res.status(400).json({
      ok: false,
      error: 'Validation error',
      details: err.errors
    });
  }

  res.status(500).json({
    ok: false,
    error: err.message || 'Internal server error'
  });
});

app.listen(port, '127.0.0.1', () => {
  console.log(`BBFS Shinobi backend running on 127.0.0.1:${port}`);
});

// OWNER_FIX_BBFS_FINAL_TABLES_APPLIED
