(function () {
  const API = "/api/public/bbfs-final-dashboard?limit=60";
  const MARKET_API = "/api/markets";

  function $(id) { return document.getElementById(id); }

  function stage() {
    return document.querySelector(".stage") || document.body;
  }

  function clean4(v) {
    return String(v || "").replace(/\D/g, "").slice(-4).padStart(4, "0");
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (m) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[m];
    });
  }

  function getMarket() {
    const selectFromResultCard = document.getElementById("bbfs-result-card-select");
    if (selectFromResultCard && selectFromResultCard.value) return selectFromResultCard.value;

    const ownSelect = document.getElementById("bbfs-home-market");
    if (ownSelect && ownSelect.value) return ownSelect.value;

    return localStorage.getItem("bbfs_result_card_market")
      || localStorage.getItem("bbfs_final_market")
      || localStorage.getItem("bbfs_next_market")
      || localStorage.getItem("bbfs_market")
      || "";
  }

  function addStyle() {
    if ($("bbfs-home-final-style")) return;

    const style = document.createElement("style");
    style.id = "bbfs-home-final-style";
    style.textContent = `
      .bbfs-home-live {
        position: absolute;
        z-index: 88;
        box-sizing: border-box;
        border: 1px solid rgba(255, 183, 72, .70);
        border-radius: 12px;
        background:
          radial-gradient(circle at 20% 20%, rgba(150, 20, 5, .42), transparent 45%),
          linear-gradient(180deg, rgba(17, 1, 0, .96), rgba(3, 0, 0, .92));
        box-shadow: inset 0 0 20px rgba(255, 90, 22, .12), 0 0 14px rgba(255, 70, 0, .18);
        color: #fff0bd;
        font-family: Georgia, "Times New Roman", serif;
        text-shadow: 0 2px 2px #000;
        overflow: hidden;
      }

      .bbfs-home-bbfs { left: 31.70%; top: 52.55%; width: 32.68%; height: 16.09%; padding: .85% 1.05%; }
      .bbfs-home-r2d  { left: 64.91%; top: 52.55%; width: 14.84%; height: 25.35%; padding: .80% .80%; }
      .bbfs-home-r3d  { left: 80.47%; top: 52.55%; width: 16.54%; height: 25.35%; padding: .80% .80%; }
      .bbfs-home-table{ left: 31.70%; top: 69.79%; width: 65.31%; height: 28.36%; padding: .75% .95%; }

      .bbfs-home-title {
        color: #fff4c9;
        font-size: clamp(10px, 1.08vw, 17px);
        font-weight: 900;
        text-transform: uppercase;
        letter-spacing: .02em;
        margin-bottom: .42em;
      }

      .bbfs-home-select {
        position: absolute;
        right: 3%;
        top: 6%;
        width: 34%;
        height: 19%;
        border-radius: 8px;
        border: 1px solid rgba(255, 196, 92, .72);
        background: rgba(5, 0, 0, .82);
        color: #ffe3a0;
        font-weight: 800;
        font-size: clamp(7px, .72vw, 11px);
        outline: none;
      }

      .bbfs-home-digits {
        display: flex;
        gap: .62em;
        align-items: center;
        margin-top: .25em;
      }

      .bbfs-home-digit {
        width: clamp(21px, 2.85vw, 47px);
        height: clamp(21px, 2.85vw, 47px);
        display: grid;
        place-items: center;
        border-radius: 50%;
        background: radial-gradient(circle at 35% 24%, #fff4bb 0%, #ffae33 44%, #591005 100%);
        border: 1px solid rgba(255, 218, 102, .95);
        color: #150300;
        font-weight: 1000;
        font-size: clamp(14px, 2.05vw, 34px);
        line-height: 1;
        box-shadow: 0 0 13px rgba(255, 93, 0, .7);
      }

      .bbfs-home-meta {
        margin-top: .42em;
        color: #ffd58a;
        font-size: clamp(7px, .78vw, 12px);
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }

      .bbfs-home-status {
        display: inline-block;
        padding: .18em .52em;
        border-radius: 999px;
        border: 1px solid rgba(255, 224, 140, .66);
        font-weight: 900;
      }

      .bbfs-home-status.AMAN { background: rgba(0, 86, 38, .88); color: #bdffd4; }
      .bbfs-home-status.WASPADA { background: rgba(116, 78, 5, .88); color: #fff0a8; }
      .bbfs-home-status.HOLD { background: rgba(91, 6, 2, .90); color: #ffd0c7; }

      .bbfs-home-rank-list {
        display: grid;
        gap: .22em;
        margin-top: .22em;
      }

      .bbfs-home-rank-row {
        display: grid;
        grid-template-columns: 1.35em 1fr auto;
        gap: .24em;
        align-items: center;
        font-size: clamp(8px, 1.05vw, 17px);
        line-height: 1.16;
      }

      .bbfs-home-rank-row .rank {
        width: 1.30em;
        height: 1.30em;
        display: grid;
        place-items: center;
        border-radius: 50%;
        border: 1px solid rgba(255, 211, 96, .80);
        color: #ffe6a8;
        font-size: .78em;
      }

      .bbfs-home-rank-row .num {
        color: #ffd86e;
        font-weight: 1000;
        letter-spacing: .08em;
      }

      .bbfs-home-rank-row .score {
        color: #e7d0a4;
        font-size: .72em;
      }

      .bbfs-home-reco-table {
        width: 100%;
        border-collapse: collapse;
        font-size: clamp(7px, .88vw, 13px);
      }

      .bbfs-home-reco-table th,
      .bbfs-home-reco-table td {
        padding: .30em .42em;
        border-bottom: 1px solid rgba(255, 183, 72, .18);
        text-align: left;
        white-space: nowrap;
      }

      .bbfs-home-reco-table th { color: #ffd889; }
      .bbfs-home-reco-table b { color: #fff3bc; }
      .bbfs-home-wait { color: #ffd58a; font-size: clamp(8px, .9vw, 13px); padding-top: .5em; }

      @media (max-width: 720px) {
        .bbfs-home-title { font-size: 10px; }
        .bbfs-home-meta { font-size: 7px; }
        .bbfs-home-rank-row { font-size: 8px; }
        .bbfs-home-reco-table { font-size: 7px; }
        .bbfs-home-select { font-size: 7px; }
      }
    `;
    document.head.appendChild(style);
  }

  function makePanel(cls, id, html) {
    let el = $(id);
    if (el) return el;

    el = document.createElement("section");
    el.id = id;
    el.className = "bbfs-home-live " + cls;
    el.innerHTML = html;

    const st = stage();
    if (st !== document.body && getComputedStyle(st).position === "static") {
      st.style.position = "relative";
    }
    st.appendChild(el);
    return el;
  }

  async function loadMarkets() {
    const select = $("bbfs-home-market");
    if (!select) return;

    try {
      const r = await fetch(MARKET_API, { cache: "no-store" });
      const j = await r.json();

      if (!j.ok || !Array.isArray(j.data)) throw new Error("API markets gagal");

      const saved = getMarket();

      select.innerHTML = j.data.map(function (m) {
        const code = esc(m.code || "");
        const name = esc(m.name || m.code || "");
        return '<option value="' + code + '">' + name + "</option>";
      }).join("");

      if (saved && j.data.some(function (m) { return m.code === saved; })) {
        select.value = saved;
      }

      select.onchange = function () {
        localStorage.setItem("bbfs_result_card_market", select.value);
        localStorage.setItem("bbfs_final_market", select.value);

        const resultSelect = document.getElementById("bbfs-result-card-select");
        if (resultSelect && resultSelect.value !== select.value) {
          resultSelect.value = select.value;
          resultSelect.dispatchEvent(new Event("change", { bubbles: true }));
        }

        loadFinal();
      };
    } catch (e) {
      select.innerHTML = '<option value="">Pasaran gagal</option>';
    }
  }

  function initPanels() {
    addStyle();

    makePanel("bbfs-home-bbfs", "bbfs-home-bbfs", `
      <div class="bbfs-home-title">BBFS 7D TERBARU</div>
      <select id="bbfs-home-market" class="bbfs-home-select"></select>
      <div id="bbfs-home-digits" class="bbfs-home-digits"><span class="bbfs-home-wait">Memuat...</span></div>
      <div id="bbfs-home-meta" class="bbfs-home-meta">-</div>
    `);

    makePanel("bbfs-home-r2d", "bbfs-home-r2d", `
      <div class="bbfs-home-title">RANKING 2D</div>
      <div id="bbfs-home-r2d-list" class="bbfs-home-rank-list"><span class="bbfs-home-wait">Memuat...</span></div>
    `);

    makePanel("bbfs-home-r3d", "bbfs-home-r3d", `
      <div class="bbfs-home-title">RANKING 3D</div>
      <div id="bbfs-home-r3d-list" class="bbfs-home-rank-list"><span class="bbfs-home-wait">Memuat...</span></div>
    `);

    makePanel("bbfs-home-table", "bbfs-home-table", `
      <table class="bbfs-home-reco-table">
        <thead>
          <tr>
            <th>Pasaran</th>
            <th>Next Draw</th>
            <th>BBFS</th>
            <th>2D Rekomendasi</th>
            <th>3D Rekomendasi</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody id="bbfs-home-reco-rows">
          <tr><td colspan="6">Memuat BBFS Final...</td></tr>
        </tbody>
      </table>
    `);
  }

  function statusClass(s) {
    return s === "AMAN" ? "AMAN" : (s === "WASPADA" ? "WASPADA" : "HOLD");
  }

  function rankList(items, maxRows) {
    if (!Array.isArray(items) || !items.length) {
      return '<span class="bbfs-home-wait">HOLD / belum ada ranking</span>';
    }

    return items.slice(0, maxRows).map(function (x, i) {
      return '<div class="bbfs-home-rank-row">' +
        '<span class="rank">' + esc(x.rank || (i + 1)) + '</span>' +
        '<span class="num">' + esc(x.number || "-") + '</span>' +
        '<span class="score">' + esc(x.score != null ? x.score : "-") + '</span>' +
      '</div>';
    }).join("");
  }

  function digitHtml(digits) {
    return String(digits || "").split("").map(function (d) {
      return '<span class="bbfs-home-digit">' + esc(d) + '</span>';
    }).join("");
  }

  function renderHold(data, message) {
    const gate = (data && data.gate) || {};
    const payload = (data && data.payload) || {};
    const bbfs = (data && data.bbfs) || payload.bbfs || {};
    const audit = bbfs.audit_digits || bbfs.digits || data.audit_digits || data.bbfs_digits || "";
    const market = (data && data.market && (data.market.name || data.market.code)) || "";
    const confidenceRaw =
      gate.confidence ||
      (gate.confidence_calibration && gate.confidence_calibration.value) ||
      0;
    const confidence = Number(confidenceRaw || 0).toFixed(2);
    const note = "Prediksi ditahan karena confidence rendah.";

    const digitsEl = $("#bbfs-home-digits");
    const metaEl = $("#bbfs-home-meta");
    const r2El = $("#bbfs-home-r2d-list");
    const r3El = $("#bbfs-home-r3d-list");
    const rowsEl = $("#bbfs-home-reco-rows");

    if (digitsEl) {
      digitsEl.innerHTML = audit
        ? digitHtml(audit)
        : '<span class="bbfs-home-wait">Kandidat BBFS belum tersedia</span>';
    }

    if (metaEl) {
      metaEl.innerHTML =
        '<span class="bbfs-home-status HOLD">HOLD</span> ' +
        esc(market) +
        ' · Confidence ' + esc(confidence) + '%' +
        ' · ' + esc(note);
    }

    if (r2El) {
      r2El.innerHTML = '<span class="bbfs-home-wait">Ranking 2D ditahan karena confidence rendah.</span>';
    }

    if (r3El) {
      r3El.innerHTML = '<span class="bbfs-home-wait">Ranking 3D ditahan karena confidence rendah.</span>';
    }

    if (rowsEl) {
      rowsEl.innerHTML =
        '<tr>' +
          '<td colspan="6">' +
            '<b>Status:</b> HOLD · ' +
            '<b>Kandidat BBFS:</b> ' + esc(audit || "-") + ' · ' +
            '<b>Catatan:</b> ' + esc(note) +
          '</td>' +
        '</tr>';
    }
  }

  function render(data) {
    const gate = data.gate || {};
    const status = gate.user_status || "HOLD";
    const predStatus = gate.prediction_status || "-";
    const confidence = Number(gate.confidence || 0).toFixed(2);
    const canShow = !!gate.can_show_prediction;

    if (!canShow) {
      renderHold(data, predStatus + " · Confidence " + confidence + "%");
      return;
    }

    const bbfs = data.bbfs || {};
    const based = data.based_on_latest_result || {};
    const r2 = data.ranking_2d || [];
    const r3 = data.ranking_3d || [];
    const poltar = data.poltar || {};
    const bbfsDigits = bbfs.digits || bbfs.audit_digits || data.audit_digits || data.bbfs_digits || "";

    $("bbfs-home-digits").innerHTML = digitHtml(bbfsDigits);
    $("bbfs-home-meta").innerHTML =
      '<span class="bbfs-home-status ' + statusClass(status) + '">' + esc(status) + '</span> ' +
      esc(data.market.name || data.market.code || "-") +
      " · Next " + esc(data.next_draw_date || "-") +
      " · Conf " + esc(confidence) + "% · Poltar " +
      esc((poltar.as ? poltar.as.digit : "-") + "/" + (poltar.kop ? poltar.kop.digit : "-") + "/" + (poltar.kepala ? poltar.kepala.digit : "-") + "/" + (poltar.ekor ? poltar.ekor.digit : "-")) +
      " · Acuan " + esc(based.draw_date || "-") + " " + esc(based.result || "-");

    $("bbfs-home-r2d-list").innerHTML = rankList(r2, 5);
    $("bbfs-home-r3d-list").innerHTML = rankList(r3, 5);

    $("bbfs-home-reco-rows").innerHTML =
      '<tr>' +
        '<td><b>' + esc(data.market.name || data.market.code || "-") + '</b></td>' +
        '<td>' + esc(data.next_draw_date || "-") + '</td>' +
        '<td><b>' + esc(bbfsDigits) + '</b></td>' +
        '<td>' + esc(r2.slice(0, 3).map(x => x.number).join(", ") || "-") + '</td>' +
        '<td>' + esc(r3.slice(0, 3).map(x => x.number).join(", ") || "-") + '</td>' +
        '<td><span class="bbfs-home-status ' + statusClass(status) + '">' + esc(status) + '</span></td>' +
      '</tr>' +
      '<tr>' +
        '<td colspan="6">Buangan: <b>' + esc(bbfs.excluded_digits || "-") + '</b> · Formula: <b>' + esc(data.formula || "FORMULA_V1_FINAL_LOCKED") + '</b> · Ranking 2D/3D hanya dari digit BBFS.</td>' +
      '</tr>';
  }

  async function loadFinal() {
    const market = getMarket();
    const url = market ? API + "&market_code=" + encodeURIComponent(market) : API;

    try {
      const r = await fetch(url, { cache: "no-store" });
      const j = await r.json();

      if (!j.ok) throw new Error(j.error || "API BBFS Final gagal");

      render(j.data);
    } catch (e) {
      renderHold(null, e.message);
    }
  }

  function bindExternalMarketSelect() {
    document.addEventListener("change", function (ev) {
      if (ev.target && ev.target.id === "bbfs-result-card-select") {
        localStorage.setItem("bbfs_result_card_market", ev.target.value);
        localStorage.setItem("bbfs_final_market", ev.target.value);

        const ownSelect = $("bbfs-home-market");
        if (ownSelect && ownSelect.value !== ev.target.value) ownSelect.value = ev.target.value;

        loadFinal();
      }
    });
  }

  async function boot() {
    document.querySelectorAll(".bbfs-db-sync-strip").forEach(el => el.remove());

    initPanels();
    bindExternalMarketSelect();
    await loadMarkets();
    await loadFinal();

    setInterval(loadFinal, 60000);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
