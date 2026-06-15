(function(){
const API_MARKETS="/api/markets",API_LATEST="/api/results/latest?limit=1";
const $=id=>document.getElementById(id);
function to4D(v){const d=String(v||"").replace(/\D/g,"");return d?d.slice(-4).padStart(4,"0"):"----"}
function dateOnly(v){return v?String(v).slice(0,10):"-"}
function dateID(v){const d=dateOnly(v);if(!/^\d{4}-\d{2}-\d{2}$/.test(d))return d;const a=d.split("-"),b=["Jan","Feb","Mar","Apr","Mei","Jun","Jul","Agu","Sep","Okt","Nov","Des"];return Number(a[2])+" "+b[Number(a[1])-1]+" "+a[0]}
function timeID(v){const m=String(v||"").match(/(\d{1,2}):(\d{2})/);return m?m[1].padStart(2,"0")+":"+m[2]+" WIB":""}
function addStyle(){if($("bbfs-result-card-style"))return;const s=document.createElement("style");s.id="bbfs-result-card-style";s.textContent=`
.bbfs-result-card-live{position:absolute;left:3.35%;top:52.15%;width:28.65%;height:29.9%;z-index:80;box-sizing:border-box;padding:1.05% 1.2%;overflow:hidden;border-radius:12px;border:1px solid rgba(255,183,72,.78);background:radial-gradient(circle at 25% 25%,rgba(170,15,0,.40),transparent 44%),linear-gradient(180deg,rgba(18,2,0,.98),rgba(4,0,0,.97));box-shadow:inset 0 0 24px rgba(255,64,16,.12),0 0 18px rgba(255,80,0,.26);color:#fff0bd;font-family:Georgia,"Times New Roman",serif;text-shadow:0 2px 2px #000}
.bbfs-result-card-live *{box-sizing:border-box}
.bbfs-result-card-title{font-size:clamp(12px,1.45vw,22px);font-weight:900;color:#fff4c9;display:flex;align-items:center;gap:.42em;line-height:1;margin-bottom:.45em;text-transform:uppercase}
.bbfs-result-card-title .icon{color:#ff2b1c;text-shadow:0 0 10px rgba(255,50,18,.9)}
.bbfs-result-card-select{width:100%;border-radius:8px;border:1px solid rgba(255,194,84,.68);background:rgba(9,0,0,.88);color:#ffe6a2;padding:.42em .55em;font-size:clamp(9px,.9vw,13px);font-weight:700;margin-bottom:.48em;outline:none}
.bbfs-result-card-label{color:#e9c98c;font-size:clamp(8px,.82vw,12px);margin-bottom:.16em}
.bbfs-result-card-period{display:inline-block;color:#fff5c7;border:1px solid rgba(255,185,72,.42);border-radius:999px;background:rgba(0,0,0,.38);padding:.15em .62em;font-size:clamp(9px,.9vw,13px);margin-bottom:.35em}
.bbfs-result-card-market{color:#ffcb74;font-size:clamp(8px,.78vw,11px);text-transform:uppercase;letter-spacing:.08em;margin-bottom:.08em}
.bbfs-result-card-number{font-family:Impact,Georgia,serif;font-size:clamp(38px,5.55vw,82px);line-height:.96;letter-spacing:.055em;color:#fff8df;text-shadow:0 0 8px rgba(255,255,255,.9),0 0 18px rgba(255,52,18,.92),0 4px 0 rgba(80,0,0,.9);margin:.04em 0 .08em}
.bbfs-result-card-bottom{display:grid;grid-template-columns:1fr auto;gap:.5em;align-items:end;color:#e8d1a0;font-size:clamp(8px,.82vw,12px)}
.bbfs-result-card-bottom b{color:#fff3bf}
.bbfs-result-card-refresh{border:1px solid rgba(255,190,72,.52);background:rgba(98,8,3,.88);color:#ffe6a2;border-radius:999px;padding:.25em .62em;font-size:clamp(8px,.72vw,10px);font-weight:800}
`;document.head.appendChild(s)}
function stage(){return document.querySelector(".stage")||document.querySelector(".dashboard-stage")||document.body}
function make(){if($("bbfs-result-card-live"))return;addStyle();const st=stage();if(st!==document.body&&getComputedStyle(st).position==="static")st.style.position="relative";const c=document.createElement("section");c.id="bbfs-result-card-live";c.className="bbfs-result-card-live";c.innerHTML=`
<div class="bbfs-result-card-title"><span class="icon">☯</span> RESULT TERBARU</div>
<select id="bbfs-result-card-select" class="bbfs-result-card-select"><option value="">Memuat pasaran...</option></select>
<div class="bbfs-result-card-label">Periode:</div>
<div id="bbfs-result-card-period" class="bbfs-result-card-period">-</div>
<div id="bbfs-result-card-market" class="bbfs-result-card-market">-</div>
<div id="bbfs-result-card-number" class="bbfs-result-card-number">----</div>
<div class="bbfs-result-card-bottom"><div><div>Terakhir diperbarui:</div><div><b id="bbfs-result-card-updated">-</b></div><div>2D: <b id="bbfs-result-card-2d">-</b> · 3D: <b id="bbfs-result-card-3d">-</b></div></div><button id="bbfs-result-card-refresh" class="bbfs-result-card-refresh" type="button">REFRESH</button></div>`;st.appendChild(c);$("bbfs-result-card-refresh").onclick=loadLatest}
async function loadMarkets(){const sel=$("bbfs-result-card-select");try{const r=await fetch(API_MARKETS,{cache:"no-store"}),j=await r.json();if(!j.ok||!Array.isArray(j.data))throw Error("API pasaran gagal");const saved=localStorage.getItem("bbfs_result_card_market")||"";sel.innerHTML='<option value="">Semua pasaran / terbaru</option>'+j.data.map(m=>{const code=String(m.code||""),name=String(m.name||m.code||"");return '<option value="'+code.replace(/"/g,"&quot;")+'">'+name+"</option>"}).join("");if(saved&&j.data.some(m=>m.code===saved))sel.value=saved;sel.onchange=()=>{localStorage.setItem("bbfs_result_card_market",sel.value);loadLatest()}}catch(e){sel.innerHTML='<option value="">Gagal memuat pasaran</option>'}}
async function loadLatest(){const sel=$("bbfs-result-card-select"),market=sel?sel.value:"",url=market?"/api/results/latest?limit=1&market_code="+encodeURIComponent(market):API_LATEST;try{const r=await fetch(url,{cache:"no-store"}),j=await r.json();if(!j.ok)throw Error(j.error||"API result gagal");const row=Array.isArray(j.data)?j.data[0]:null;if(!row){$("bbfs-result-card-period").textContent="-";$("bbfs-result-card-market").textContent=market||"-";$("bbfs-result-card-number").textContent="----";$("bbfs-result-card-updated").textContent="-";$("bbfs-result-card-2d").textContent="-";$("bbfs-result-card-3d").textContent="-";return}const r4=to4D(row.result_4d||row.result),t=timeID(row.result_time),u=t?dateID(row.draw_date)+" "+t:dateID(row.draw_date);$("bbfs-result-card-period").textContent=dateOnly(row.draw_date);$("bbfs-result-card-market").textContent=row.market_name||row.market_code||"-";$("bbfs-result-card-number").textContent=r4;$("bbfs-result-card-updated").textContent=u;$("bbfs-result-card-2d").textContent=r4.slice(-2);$("bbfs-result-card-3d").textContent=r4.slice(-3)}catch(e){$("bbfs-result-card-updated").textContent="Gagal ambil data"}}
async function boot(){make();await loadMarkets();await loadLatest();setInterval(loadLatest,60000)}
document.readyState==="loading"?document.addEventListener("DOMContentLoaded",boot):boot();
})();
