#!/usr/bin/env bash
set -euo pipefail
WEB=/var/www/jhunaey.my.id
BE=/opt/bbfs-shinobi/backend
HTML=$WEB/manual-fetch.html
ENV=$BE/.env
[ -f "$HTML" ] || { echo "GAGAL: $HTML tidak ada"; exit 1; }
[ -f "$ENV" ] || { echo "GAGAL: $ENV tidak ada"; exit 1; }
read -r -p "Masukkan PIN admin 6-12 angka: " PIN
case "$PIN" in (*[!0-9]*|'') echo "PIN harus angka"; exit 1;; esac
if [ ${#PIN} -lt 6 ] || [ ${#PIN} -gt 12 ]; then echo "PIN harus 6-12 digit"; exit 1; fi
if grep -q '^ADMIN_API_TOKEN=' "$ENV"; then sed -i "s/^ADMIN_API_TOKEN=.*/ADMIN_API_TOKEN=$PIN/" "$ENV"; else echo "ADMIN_API_TOKEN=$PIN" >> "$ENV"; fi
cp "$HTML" "$HTML.bak-pinvisible-$(date +%Y%m%d-%H%M%S)"
python3 - <<'PY'
from pathlib import Path
p=Path('/var/www/jhunaey.my.id/manual-fetch.html')
s=p.read_text(encoding='utf-8')
s=s.replace('Admin Token','PIN Admin')
s=s.replace('admin token','PIN admin').replace('Admin token','PIN admin')
s=s.replace('bbfs_shinobi_admin_token_sementara','')
patch=r'''
<script id="bbfs-force-pin-visible-v2">
(function(){
function run(){
  document.querySelectorAll('label').forEach(l=>{if((l.textContent||'').toLowerCase().includes('pin admin')||(l.textContent||'').toLowerCase().includes('admin token'))l.textContent='PIN Admin';});
  const input=document.querySelector('#adminToken,input[id*=token i],input[name*=token i]');
  if(input){input.type='password';input.inputMode='numeric';input.placeholder='Isi PIN admin';input.autocomplete='off';input.value=localStorage.getItem('bbfs_admin_pin')||'';input.oninput=()=>localStorage.setItem('bbfs_admin_pin',input.value.trim());}
}
const oldFetch=window.fetch;
window.fetch=function(i,o){o=o||{};let u=String(i&&i.url||i||'');if(u.includes('/api/')){let h=new Headers(o.headers||{});let p=(localStorage.getItem('bbfs_admin_pin')||document.querySelector('#adminToken')?.value||'').trim();if(p){h.set('Authorization','Bearer '+p);h.set('X-Admin-Pin',p)}o.headers=h;}return oldFetch(i,o)};
window.addEventListener('DOMContentLoaded',run);setTimeout(run,500);setTimeout(run,1500);
})();
</script>
'''
if 'bbfs-force-pin-visible-v2' not in s:
    s=s.replace('</body>',patch+'</body>') if '</body>' in s else s+patch
p.write_text(s,encoding='utf-8')
PY
systemctl restart bbfs-backend
systemctl reload nginx
echo "OK: buka https://jhunaey.my.id/manual-fetch.html?v=pin-visible-v2"
