const axios = require('axios');
const cheerio = require('cheerio');
const fs = require('fs');
const path = require('path');

const BASE = 'https://prediksi89.angka-alexis.pro';
const PAGE = BASE + '/?page=data-keluaran-togel';
const OUT = '/opt/bbfs-shinobi/source-inspect';

function absUrl(src) {
  return new URL(src, BASE + '/').toString();
}

(async () => {
  fs.mkdirSync(OUT, { recursive: true });

  const page = await axios.get(PAGE, {
    timeout: 30000,
    headers: { 'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0' }
  });

  fs.writeFileSync(path.join(OUT, 'page.html'), page.data);

  const $ = cheerio.load(page.data);
  const scripts = [];

  $('script[src]').each((_, el) => {
    const src = $(el).attr('src');
    if (src) scripts.push(absUrl(src));
  });

  console.log('Scripts:', scripts.length);

  for (const url of scripts) {
    const name = url.split('/').pop().split('?')[0] || 'script.js';
    const out = path.join(OUT, name);

    try {
      const res = await axios.get(url, {
        timeout: 30000,
        headers: {
          'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0',
          'Referer': PAGE
        }
      });

      const text = typeof res.data === 'string' ? res.data : JSON.stringify(res.data);
      fs.writeFileSync(out, text);

      console.log('OK', url, text.length);

      const lines = text.split(/\r?\n/);
      lines.forEach((line, idx) => {
        if (/ajax|fetch|getJSON|post|get|url|data-keluaran|keluaran|result|pasaran|paginate|search/i.test(line)) {
          console.log(`${name}:${idx + 1}: ${line.slice(0, 300)}`);
        }
      });
    } catch (e) {
      console.log('ERR', url, e.message);
    }
  }
})();
