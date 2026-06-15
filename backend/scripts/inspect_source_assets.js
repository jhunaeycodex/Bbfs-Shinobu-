const axios = require('axios');
const cheerio = require('cheerio');

const BASE = 'https://prediksi89.angka-alexis.pro';
const URL = BASE + '/?page=data-keluaran-togel';

(async () => {
  const res = await axios.get(URL, {
    timeout: 15000,
    headers: { 'User-Agent': 'Mozilla/5.0 BBFS-Shinobi/1.0' }
  });

  const $ = cheerio.load(res.data);

  console.log('HTML length:', String(res.data).length);

  console.log('\nSCRIPT SRC:');
  $('script[src]').each((_, el) => {
    const src = $(el).attr('src');
    console.log(src && src.startsWith('http') ? src : BASE + src);
  });

  console.log('\nFORM ACTION:');
  $('form').each((_, el) => {
    console.log($(el).attr('action'), $(el).attr('method'));
  });

  console.log('\nSELECT / INPUT NAME:');
  $('select,input,button').each((_, el) => {
    console.log(el.name, $(el).attr('name'), $(el).attr('id'), $(el).attr('class'), $(el).attr('value'));
  });

  console.log('\nINLINE KEYWORDS:');
  const html = String(res.data);
  for (const kw of ['ajax', 'fetch', 'axios', 'result', 'keluaran', 'pasaran', 'getJSON', '$.post', '$.get']) {
    const idx = html.toLowerCase().indexOf(kw.toLowerCase());
    console.log(kw, idx);
    if (idx >= 0) console.log(html.slice(Math.max(0, idx - 200), idx + 400));
  }
})().catch(e => {
  console.error(e.message);
  process.exit(1);
});
