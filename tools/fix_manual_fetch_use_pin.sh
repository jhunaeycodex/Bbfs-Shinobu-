#!/usr/bin/env bash
set -euo pipefail
WEB=/var/www/jhunaey.my.id
BE=/opt/bbfs-shinobi/backend
HTML=$WEB/manual-fetch.html
ENV=$BE/.env
REPORT=/opt/bbfs-github-sync/reports/fix_manual_fetch_use_pin.txt
mkdir -p /opt/bbfs-github-sync/reports
: > "$REPORT"
echo "FIX MANUAL FETCH USE PIN" >> "$REPORT"
[ -f "$HTML" ] || { echo "manual-fetch.html tidak ditemukan: $HTML" | tee -a "$REPORT"; exit 1; }
[ -f "$ENV" ] || { echo ".env backend tidak ditemukan: $ENV" | tee -a "$REPORT"; exit 1; }
PIN="${PIN:-}"
if [ -z "$PIN" ]; then
  read -r -p "Masukkan PIN admin 6-12 angka: " PIN
fi
case "$PIN" in (*[!0-9]*|'') echo "PIN harus angka"; exit 1;; esac
if [ ${#PIN} -lt 6 ] || [ ${#PIN} -gt 12 ]; then echo "PIN harus 6-12 digit"; exit 1; fi
if grep -q '^ADMIN_API_TOKEN=' "$ENV"; then
  sed -i "s/^ADMIN_API_TOKEN=.*/ADMIN_API_TOKEN=$PIN/" "$ENV"
else
  printf '\nADMIN_API_TOKEN=%s\n' "$PIN" >> "$ENV"
fi
cp "$HTML" "$HTML.bak-pin-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/jhunaey.my.id/manual-fetch.html')
s=p.read_text(encoding='utf-8')
block='''
<script id="bbfs-pin-auth-patch">
(function(){
  if(window.__BBFS_PIN_AUTH_PATCH__) return; window.__BBFS_PIN_AUTH_PATCH__=true;
  function el(id){return document.getElementById(id)}
  function pin(){return (localStorage.getItem('bbfs_admin_pin')||'').trim()}
  var bar=document.createElement('div');
  bar.style.cssText='position:sticky;top:0;z-index:9999;background:#111827;color:#fff;padding:10px;border-bottom:1px solid #374151;font:14px Arial';
  bar.innerHTML='PIN Admin: <input id="bbfsAdminPin" type="password" inputmode="numeric" style="padding:7px;border-radius:8px;border:1px solid #555;background:#0b1220;color:#fff" placeholder="isi PIN"> <button id="bbfsSavePin" style="padding:7px 10px;border-radius:8px">Simpan PIN</button> <span id="bbfsPinInfo" style="margin-left:8px;color:#9ca3af"></span>';
  document.body.prepend(bar);
  if(pin()) el('bbfsAdminPin').value=pin();
  el('bbfsSavePin').onclick=function(){localStorage.setItem('bbfs_admin_pin',el('bbfsAdminPin').value.trim());el('bbfsPinInfo').textContent='PIN tersimpan';setTimeout(function(){el('bbfsPinInfo').textContent=''},1800)};
  var oldFetch=window.fetch;
  window.fetch=function(input,init){
    init=init||{}; var url=String(input&&input.url||input||'');
    if(url.indexOf('/api/')===0 || url.indexOf(location.origin+'/api/')===0){
      var h=new Headers(init.headers||{}); var p=pin()||el('bbfsAdminPin').value.trim();
      if(p){h.set('Authorization','Bearer '+p);h.set('X-Admin-Pin',p)}
      init.headers=h;
    }
    return oldFetch(input,init);
  };
})();
</script>
'''
if 'bbfs-pin-auth-patch' not in s:
    s=s.replace('</body>', block+'\n</body>') if '</body>' in s else s+block
p.write_text(s,encoding='utf-8')
PY
systemctl restart bbfs-backend
systemctl reload nginx
echo "OK: manual-fetch pakai PIN" | tee -a "$REPORT"
echo "Buka: https://jhunaey.my.id/manual-fetch.html?v=pin" | tee -a "$REPORT"
if command -v bbfs-push-github >/dev/null 2>&1; then bbfs-push-github >/dev/null 2>&1 || true; fi
