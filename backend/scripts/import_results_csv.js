require('dotenv').config();

const fs = require('fs');
const path = require('path');
const { parse } = require('csv-parse/sync');
const { Pool } = require('pg');

const pool = new Pool({
  connectionString: process.env.DATABASE_URL
});

function slugify(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/&/g, 'and')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
}

function titleCase(value) {
  return String(value || '')
    .trim()
    .replace(/[-_]+/g, ' ')
    .replace(/\s+/g, ' ')
    .replace(/\b\w/g, c => c.toUpperCase());
}

function cleanResult(value) {
  const digits = String(value || '').replace(/\D/g, '');
  if (!/^[0-9]{2,7}$/.test(digits)) {
    throw new Error('Result tidak valid: ' + value);
  }
  return digits;
}

function cleanDate(value) {
  const raw = String(value || '').trim();

  if (/^\d{4}-\d{2}-\d{2}$/.test(raw)) {
    return raw;
  }

  const m = raw.match(/^(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})$/);
  if (m) {
    return `${m[3]}-${m[2].padStart(2, '0')}-${m[1].padStart(2, '0')}`;
  }

  throw new Error('Tanggal tidak valid: ' + value);
}

async function ensureMarket(client, code, name) {
  const existing = await client.query(
    'SELECT id FROM markets WHERE code = $1',
    [code]
  );

  if (existing.rowCount > 0) {
    return existing.rows[0].id;
  }

  const inserted = await client.query(`
    INSERT INTO markets (code, name, timezone, is_active, display_order)
    VALUES ($1, $2, 'Asia/Jakarta', TRUE, 999)
    RETURNING id
  `, [code, name]);

  await client.query(`
    INSERT INTO market_profiles (market_id)
    VALUES ($1)
    ON CONFLICT (market_id) DO NOTHING
  `, [inserted.rows[0].id]);

  return inserted.rows[0].id;
}

async function main() {
  const filePath = process.argv[2];

  if (!filePath) {
    console.error('Pakai: node scripts/import_results_csv.js /path/results.csv');
    process.exit(1);
  }

  const absolutePath = path.resolve(filePath);
  const csvText = fs.readFileSync(absolutePath, 'utf8');

  const records = parse(csvText, {
    columns: true,
    bom: true,
    skip_empty_lines: true,
    trim: true
  });

  const client = await pool.connect();

  let batchId = null;
  let success = 0;
  let errors = 0;
  const marketCache = new Map();

  try {
    const batch = await client.query(`
      INSERT INTO import_batches (filename, status, total_rows)
      VALUES ($1, 'running', $2)
      RETURNING id
    `, [path.basename(absolutePath), records.length]);

    batchId = batch.rows[0].id;

    for (let i = 0; i < records.length; i++) {
      const row = records[i];

      try {
        const pasaran = row.pasaran || row.market || row.market_name || row.name;
        const tanggal = row.tanggal || row.draw_date || row.date || row.periode;
        const result = row.result || row.angka || row.keluaran || row.nomor;

        if (!pasaran) throw new Error('Kolom pasaran kosong');
        if (!tanggal) throw new Error('Kolom tanggal kosong');
        if (!result) throw new Error('Kolom result kosong');

        const marketCode = slugify(pasaran);
        const marketName = titleCase(pasaran);
        const drawDate = cleanDate(tanggal);
        const resultNumber = cleanResult(result);

        let marketId = marketCache.get(marketCode);

        if (!marketId) {
          marketId = await ensureMarket(client, marketCode, marketName);
          marketCache.set(marketCode, marketId);
        }

        await client.query(`
          INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
          VALUES ($1, $2, $3, 'csv-import', $4::jsonb)
          ON CONFLICT (market_id, draw_date)
          DO UPDATE SET
            result = EXCLUDED.result,
            source = EXCLUDED.source,
            raw_payload = EXCLUDED.raw_payload,
            updated_at = NOW()
        `, [marketId, drawDate, resultNumber, JSON.stringify(row)]);

        success++;
      } catch (error) {
        errors++;

        await client.query(`
          INSERT INTO import_errors (batch_id, row_number, row_payload, error_message)
          VALUES ($1, $2, $3::jsonb, $4)
        `, [batchId, i + 2, JSON.stringify(row), error.message]);

        if (errors <= 20) {
          console.error('Row ' + (i + 2) + ': ' + error.message);
        }
      }

      if ((i + 1) % 1000 === 0) {
        console.log(`Progress ${i + 1}/${records.length} | success=${success} | errors=${errors}`);
      }
    }

    await client.query(`
      UPDATE import_batches
      SET status = $1,
          success_rows = $2,
          error_rows = $3,
          finished_at = NOW()
      WHERE id = $4
    `, [
      errors > 0 ? 'completed_with_errors' : 'completed',
      success,
      errors,
      batchId
    ]);

    await client.query(`
      INSERT INTO sync_logs (entity, action, status, message)
      VALUES ('result_draw', 'csv_import', $1, $2)
    `, [
      errors > 0 ? 'completed_with_errors' : 'success',
      `CSV import selesai. success=${success}, errors=${errors}`
    ]);

    console.log('IMPORT SELESAI');
    console.log({
      total: records.length,
      success,
      errors,
      batchId
    });
  } finally {
    client.release();
    await pool.end();
  }
}

main().catch(error => {
  console.error('IMPORT GAGAL:', error.message);
  process.exit(1);
});
