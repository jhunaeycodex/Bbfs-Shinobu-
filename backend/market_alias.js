const axios = require('axios');
const cheerio = require('cheerio');

function normalizeMarketCode(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/&/g, 'and')
    .replace(/\+/g, 'plus')
    .replace(/[^a-z0-9:_-]+/g, '-')
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

function normalizeMarketName(value, code) {
  const raw = String(value || '').replace(/\s*\[NOT-SOURCE-HIDDEN\]\s*$/i, '').trim();
  if (raw) return raw;

  return String(code || '')
    .replace(/[-_:]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
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

  if (options.length > 0) return options;

  const bodyText = $.text().replace(/\s+/g, ' ').trim();
  const m = bodyText.match(/Pilih Pasaran\s+(.+?)\s+Mohon ditunggu/i);
  if (!m) return [];

  for (const token of m[1].split(/\s+/).filter(Boolean)) {
    const source_value = token.trim();
    const source_code = normalizeMarketCode(source_value);
    const key = `${source_code}|${source_value}`;
    if (seen.has(key)) continue;
    seen.add(key);
    options.push({ source_name: titleCase(source_value), source_value, source_code });
  }

  return options;
}

async function resolveAliasByCanonical(client, sourceUrl, canonicalMarketCode) {
  const code = normalizeMarketCode(canonicalMarketCode);
  const result = await client.query(`
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
      m.code AS market_code,
      m.name AS market_name
    FROM market_source_aliases a
    JOIN markets m ON m.id = a.canonical_market_id
    WHERE a.source_url = $1
      AND a.is_active = TRUE
      AND m.is_active = TRUE
      AND (m.code = $2 OR a.source_code = $2 OR a.source_value = $2 OR LOWER(a.source_name) = LOWER($2))
    ORDER BY
      CASE
        WHEN m.code = $2 THEN 0
        WHEN a.source_code = $2 THEN 1
        WHEN a.source_value = $2 THEN 2
        WHEN LOWER(a.source_name) = LOWER($2) THEN 3
        ELSE 4
      END,
      a.source_code ASC
    LIMIT 1
  `, [sourceUrl, code]);

  if (result.rowCount === 0) return null;
  return result.rows[0];
}

async function resolveAliasBySourceOption(client, sourceUrl, sourceValue, sourceName) {
  const value = String(sourceValue || '').trim();
  const name = String(sourceName || '').trim();
  const code = normalizeMarketCode(value || name);

  const result = await client.query(`
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
      m.code AS market_code,
      m.name AS market_name
    FROM market_source_aliases a
    JOIN markets m ON m.id = a.canonical_market_id
    WHERE a.source_url = $1
      AND a.is_active = TRUE
      AND m.is_active = TRUE
      AND (
        a.source_code = $2
        OR a.source_value = $2
        OR LOWER(a.source_name) = LOWER($3)
        OR m.code = $2
      )
    ORDER BY
      CASE
        WHEN a.source_code = $2 THEN 0
        WHEN a.source_value = $2 THEN 1
        WHEN LOWER(a.source_name) = LOWER($3) THEN 2
        WHEN m.code = $2 THEN 3
        ELSE 4
      END,
      a.source_code ASC
    LIMIT 1
  `, [sourceUrl, code, name]);

  if (result.rowCount === 0) return null;
  return result.rows[0];
}

function buildPayload(sourceUrl, aliasRow, raw) {
  return JSON.stringify({
    source_url: sourceUrl,
    source_name: aliasRow.source_name,
    source_value: aliasRow.source_value,
    source_code: aliasRow.source_code,
    canonical_market_id: aliasRow.canonical_market_id,
    canonical_market_code: aliasRow.canonical_market_code,
    canonical_market_name: aliasRow.canonical_market_name,
    raw
  });
}

async function saveCanonicalResult(client, entry) {
  const existing = await client.query(`
    SELECT id, market_id, result, source
    FROM result_draws
    WHERE market_id = $1
      AND draw_date = $2
    LIMIT 1
  `, [entry.canonical_market_id, entry.draw_date]);

  if (existing.rowCount === 0) {
    const inserted = await client.query(`
      INSERT INTO result_draws (market_id, draw_date, result, source, raw_payload)
      VALUES ($1, $2, $3, $4, $5::jsonb)
      RETURNING id
    `, [
      entry.canonical_market_id,
      entry.draw_date,
      entry.result,
      entry.source_tag,
      buildPayload(entry.sourceUrl, entry, entry.raw)
    ]);

    return { inserted: 1, unchanged: 0, conflicts: 0, updated: 0, id: inserted.rows[0].id };
  }

  if (existing.rows[0].result === entry.result) {
    return { inserted: 0, unchanged: 1, conflicts: 0, updated: 0, id: existing.rows[0].id };
  }

  await client.query(`
    INSERT INTO market_source_alias_conflicts (
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
      notes
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
  `, [
    entry.source_name,
    entry.source_value,
    entry.source_code,
    entry.canonical_market_id,
    entry.canonical_market_code,
    entry.canonical_market_name,
    entry.sourceUrl,
    entry.draw_date,
    existing.rows[0].result,
    entry.result,
    existing.rows[0].source,
    entry.source_tag,
    existing.rows[0].market_id,
    entry.canonical_market_id,
    'source_overwrite: old result saved, database updated to source result'
  ]);

  const updatedRow = await client.query(`
    UPDATE result_draws
    SET result = $1,
        source = $2,
        raw_payload = $3::jsonb,
        updated_at = NOW()
    WHERE id = $4
    RETURNING id
  `, [
    entry.result,
    entry.source_tag,
    buildPayload(entry.sourceUrl, entry, entry.raw),
    existing.rows[0].id
  ]);

  return { inserted: 0, unchanged: 0, conflicts: 0, updated: 1, id: updatedRow.rows[0].id };
}

module.exports = {
  fetchSourceMarketOptions,
  normalizeMarketCode,
  normalizeMarketName,
  normalizeCanonicalMarketName,
  resolveAliasByCanonical,
  resolveAliasBySourceOption,
  saveCanonicalResult,
  titleCase
};
