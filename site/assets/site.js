// The mobile menu, and the download links from the latest GitHub release.
(function () {
  var toggle = document.querySelector(".menu-toggle");
  var nav = document.querySelector(".topnav");
  if (toggle && nav) {
    toggle.addEventListener("click", function () {
      var open = nav.classList.toggle("open");
      toggle.setAttribute("aria-expanded", open ? "true" : "false");
    });
  }

  var REPO = "highercomve/GhostPen";
  var RELEASES = "https://github.com/" + REPO + "/releases";

  function visitorOs() {
    var ua = [navigator.userAgent, navigator.platform, navigator.userAgentData && navigator.userAgentData.platform].join(" ");
    if (/win/i.test(ua)) return "windows";
    if (/mac|iphone|ipad/i.test(ua)) return "macos";
    return "linux";
  }

  // What an asset is, from its file name (the names `oriel package` gives).
  function describe(name) {
    var arch = /(aarch64|arm64)/i.test(name) ? "ARM64" : /(x86_64|amd64|x64)/i.test(name) ? "x86-64" : "";
    if (/\.AppImage$/i.test(name)) return { os: "linux", kind: "AppImage", order: 0, arch: arch };
    if (/\.deb$/i.test(name)) return { os: "linux", kind: "Debian / Ubuntu (.deb)", order: 1, arch: arch };
    if (/\.rpm$/i.test(name)) return { os: "linux", kind: "Fedora / openSUSE (.rpm)", order: 2, arch: arch };
    if (/setup\.exe$/i.test(name)) return { os: "windows", kind: "Installer (.exe)", order: 0, arch: arch || "x86-64" };
    if (/\.dmg$/i.test(name)) return { os: "macos", kind: "Disk image (.dmg)", order: 0, arch: arch || "Apple Silicon" };
    return null;
  }

  function formatSize(bytes) {
    return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + " GB" : Math.max(1, Math.round(bytes / 1e6)) + " MB";
  }

  var OS_NAME = { linux: "Linux", windows: "Windows", macos: "macOS" };
  var os = visitorOs();
  var card = document.querySelector('[data-os-card="' + os + '"]');
  if (card) card.classList.add("current");

  function noRelease() {
    document.querySelectorAll("[data-os-links]").forEach(function (el) {
      el.innerHTML = '<span class="dl-empty">No release yet: see <a href="' + RELEASES + '">GitHub releases</a>.</span>';
    });
  }

  fetch("https://api.github.com/repos/" + REPO + "/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (release) {
      var version = release.tag_name || "";
      document.querySelectorAll("[data-latest-version]").forEach(function (el) { el.textContent = version; el.hidden = !version; });
      var info = document.querySelector("[data-release-info]");
      if (info && version) {
        var date = release.published_at ? new Date(release.published_at).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" }) : "";
        info.innerHTML = 'GhostPen <a href="' + release.html_url + '">' + version + "</a>" + (date ? ", released " + date : "") + ".";
      }
      var byOs = { linux: [], windows: [], macos: [] };
      (release.assets || []).forEach(function (a) {
        var d = describe(a.name);
        if (d) byOs[d.os].push({ url: a.browser_download_url, size: a.size, d: d });
      });
      Object.keys(byOs).forEach(function (k) {
        var list = byOs[k].sort(function (a, b) { return a.d.order - b.d.order || a.d.arch.localeCompare(b.d.arch); });
        var el = document.querySelector('[data-os-links="' + k + '"]');
        if (!el) return;
        el.innerHTML = "";
        if (!list.length) {
          el.innerHTML = '<span class="dl-empty">Not in this release: see <a href="' + RELEASES + '">all releases</a>.</span>';
          return;
        }
        list.forEach(function (x) {
          var a = document.createElement("a");
          a.href = x.url;
          a.innerHTML = "<span></span><small></small>";
          a.firstChild.textContent = x.d.kind + (x.d.arch ? " · " + x.d.arch : "");
          a.lastChild.textContent = formatSize(x.size);
          el.appendChild(a);
        });
      });
      // The hero button: the first file for the visitor's OS.
      var mine = byOs[os][0];
      var btn = document.querySelector("[data-download-primary]");
      if (btn && mine) {
        btn.href = mine.url;
        document.querySelector("[data-download-label]").textContent = "Download for " + OS_NAME[os];
        var note = document.querySelector("[data-download-note]");
        if (note) note.innerHTML = version + " · " + mine.d.kind + " · " + formatSize(mine.size) + ' · <a href="#download">Other platforms</a>';
      }
    })
    .catch(noRelease);
})();
