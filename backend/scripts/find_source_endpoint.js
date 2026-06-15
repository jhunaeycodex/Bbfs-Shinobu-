const axios = require('axios');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');

const BASE = 'https://prediksi89.angka-alexis.pro/';
const PAGE = 'https://prediksi89.angka-alexis.pro/?page=data-keluaran-togel';
const OUT = '/opt/bbfs-shinobi/source-inspect';

function absUrl(src) {
  return new URL(src, BASE).toString();
}

function safeName(url) {
  return url.replace(/^https?:\/\//, '').replace(/[^a-z0-9._-]+/gi, '_').slice(-160);
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });

  console.log('[2/4] Download halaman sumber...');
  const pageRes = await axios.get(PAGE, {
    timeout: 30000,
    maxBodyLength: Infinity,
    maxContentLength: Infinity,
    headers: {
      'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0'
    }
  });

  const html = String(pageRes.data || '');
  fs.writeFileSync(path.join(OUT, 'page.html'), html);
  console.log('PAGE_HTML_LENGTH=' + html.length);

  const $ = cheerio.load(html);
  const scripts = [];

  $('script[src]').each((_, el) => {
    const raw = $(el).attr('src');
    if (!raw) return;
    const url = absUrl(raw);
    if (url.includes('angka-alexis.pro')) scripts.push(url);
  });

  console.log('SCRIPT_COUNT=' + scripts.length);
  scripts.forEach(x => console.log('SCRIPT=' + x));

  console.log('[3/4] Download JS...');
  for (const url of scripts) {
    try {
      const res = await axios.get(url, {
        timeout: 30000,
        maxBodyLength: Infinity,
        maxContentLength: Infinity,
        headers: {
          'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0',
          'Referer': PAGE
        }
      });
      const text = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
      const outFile = path.join(OUT, safeName(url));
      fs.writeFileSync(outFile, text);
      console.log('DOWNLOADED=' + outFile + ' SIZE=' + text.length);
    } catch (err) {
      console.log('JS_DOWNLOAD_ERROR=' + url + ' :: ' + err.message);
    }
  }

  console.log('[4/4] Cari endpoint/kode dropdown...');
  const files = fs.readdirSync(OUT)
    .filter(f => f.endsWith('.js') || f.includes('.js'))
    .map(f => path.join(OUT, f));

  let hits = 0;

  const patterns = [
    /ajax\s*\(/i,
    /\$\.ajax/i,
    /\$\.post/i,
    /\$\.get/i,
    /fetch\s*\(/i,
    /axios/i,
    /XMLHttpRequest/i,
    /data-keluaran/i,
    /keluaran/i,
    /result/i,
    /pasaran/i,
    /search-btn/i,
    /form-control/i,
    /\.load\s*\(/i,
    /url\s*:/i
  ];

  for (const file of files) {
    const text = fs.readFileSync(file, 'utf8');
    const lines = text.split(/\r?\n/);

    lines.forEach((line, idx) => {
      if (patterns.some(re => re.test(line))) {
        hits++;
        console.log(`${path.basename(file)}:${idx + 1}: ${line.trim().slice(0, 500)}`);
      }
    });

    // JS minified: print surrounding chunks too
    const lower = text.toLowerCase();
    for (const kw of ['ajax', 'fetch(', '$.post', '$.get', 'data-keluaran', 'keluaran', 'result', 'pasaran', 'search-btn']) {
      let pos = lower.indexOf(kw.toLowerCase());
      let c = 0;
      while (pos >= 0 && c < 5) {
        hits++;
        const start = Math.max(0, pos - 180);
        const end = Math.min(text.length, pos + 420);
        console.log(`CHUNK ${path.basename(file)} ${kw}: ${text.slice(start, end).replace(/\s+/g, ' ')}`);
        pos = lower.indexOf(kw.toLowerCase(), pos + kw.length);
        c++;
      }
    }
  }

  console.log('TOTAL_HITS=' + hits);
  console.log('SAVED_DIR=' + OUT);
})().catch(err => {
  console.error('FATAL=' + err.stack);
  process.exit(1);
});
