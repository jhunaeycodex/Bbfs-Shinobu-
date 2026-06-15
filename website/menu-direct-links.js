(function () {
  const RESULT_URL = "/manual-fetch.html?v=crud-result";
  const BBFS_URL = "/bbfs-next-draw.html?v=final-rules";

  function stage() {
    return document.querySelector(".stage") || document.querySelector(".dashboard-stage") || document.body;
  }

  function addStyle() {
    if (document.getElementById("menu-direct-links-style")) return;

    const style = document.createElement("style");
    style.id = "menu-direct-links-style";
    style.textContent = `
      .menu-direct-hotspot {
        position: absolute;
        z-index: 120;
        display: block;
        background: transparent;
        border: 0;
        outline: 0;
        text-decoration: none;
        cursor: pointer;
        -webkit-tap-highlight-color: rgba(255, 180, 60, .22);
      }

      .menu-direct-hotspot:active {
        background: rgba(255, 180, 60, .08);
      }

      /*
        Fallback posisi untuk menu gambar statis.
        Jika index sudah punya hotspot asli, href-nya juga sudah dipatch oleh installer.
      */
      .menu-direct-result {
        left: 13.0%;
        top: 8.6%;
        width: 16.0%;
        height: 5.8%;
      }

      .menu-direct-bbfs {
        left: 30.4%;
        top: 8.6%;
        width: 16.2%;
        height: 5.8%;
      }

      @media (max-width: 720px) {
        .menu-direct-result {
          left: 12.6%;
          top: 8.2%;
          width: 16.8%;
          height: 6.2%;
        }

        .menu-direct-bbfs {
          left: 30.0%;
          top: 8.2%;
          width: 16.8%;
          height: 6.2%;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function makeHotspot(id, cls, href, label) {
    if (document.getElementById(id)) return;

    const st = stage();
    if (st !== document.body && getComputedStyle(st).position === "static") {
      st.style.position = "relative";
    }

    const a = document.createElement("a");
    a.id = id;
    a.className = "menu-direct-hotspot " + cls;
    a.href = href;
    a.setAttribute("aria-label", label);
    a.title = label;

    st.appendChild(a);
  }

  function patchExistingLinks() {
    document.querySelectorAll("a").forEach(function (a) {
      const text = ((a.textContent || "") + " " + (a.className || "") + " " + (a.id || "") + " " + (a.href || "")).toLowerCase();

      if (text.includes("result") && !text.includes("bbfs")) {
        a.href = RESULT_URL;
      }

      if (text.includes("bbfs")) {
        a.href = BBFS_URL;
      }
    });
  }

  function boot() {
    addStyle();
    patchExistingLinks();

    makeHotspot("menu-direct-result", "menu-direct-result", RESULT_URL, "Result menuju Manual Fetch");
    makeHotspot("menu-direct-bbfs", "menu-direct-bbfs", BBFS_URL, "BBFS menuju BBFS Final Next Draw");
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
