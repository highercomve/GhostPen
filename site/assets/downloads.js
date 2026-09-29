// Resolve the latest release assets into direct file links for the Flow concept.
// The Pages build writes the latest release to release.json, so visitors don't
// hit GitHub's API rate limit; the live API is only a fallback.
(() => {
  const endpoint = 'https://api.github.com/repos/highercomve/GhostPen/releases/latest';
  const cached = document.querySelector('[data-release-json]')?.dataset.releaseJson;
  const version = document.querySelector('[data-release-version]');
  const primary = document.querySelector('[data-primary-download]');
  const cards = [...document.querySelectorAll('[data-download-os]')];
  const os = /Win/i.test(navigator.userAgent) ? 'windows' : /Mac/i.test(navigator.userAgent) ? 'macos' : 'linux';

  function describe(name) {
    const cuda = /-cuda\b/i.test(name);
    const gpu = cuda ? 'cuda' : 'vulkan';
    const linux = (format, title, rank) => ({ os:'linux', format, gpu, label:title + (cuda ? ' · NVIDIA CUDA' : ' · Vulkan'), priority:rank + (cuda ? 3 : 0) });
    if (/\.AppImage$/i.test(name)) return linux('appimage', 'AppImage', 0);
    if (/\.deb$/i.test(name)) return linux('deb', 'Debian / Ubuntu (.deb)', 1);
    if (/\.rpm$/i.test(name)) return linux('rpm', 'Fedora / openSUSE (.rpm)', 2);
    if (/-setup\.exe$/i.test(name)) return { os:'windows', label:'Windows installer (.exe)', specs:[['Package','Installer (.exe)'],['GPU','Vulkan or CPU']], priority:0 };
    if (/\.dmg$/i.test(name)) return { os:'macos', label:'macOS disk image (.dmg)', specs:[['Package','Disk image (.dmg)'],['GPU','Apple Metal']], priority:0 };
    return null;
  }
  function size(bytes) {
    return bytes >= 1e9 ? (bytes / 1e9).toFixed(1) + ' GB' : Math.round(bytes / 1e6) + ' MB';
  }
  const FORMATS = [['appimage','AppImage'],['deb','.deb'],['rpm','.rpm']];
  const GPUS = [['vulkan','Vulkan'],['cuda','NVIDIA CUDA']];
  function downloadLink(asset) {
    const link = document.createElement('a');
    const label = document.createElement('span');
    const meta = document.createElement('small');
    link.append(label, meta);
    link.set = next => {
      link.href = next.url;
      link.setAttribute('aria-label', 'Download ' + next.label + ', ' + size(next.bytes));
      label.textContent = '↓  Download';
      meta.textContent = size(next.bytes);
    };
    link.set(asset);
    return link;
  }
  function choice(title, name, options) {
    const set = document.createElement('fieldset');
    set.className = 'asset-choice';
    const legend = document.createElement('legend');
    legend.textContent = title;
    const row = document.createElement('div');
    row.className = 'asset-options';
    options.forEach(([value, text]) => {
      const label = document.createElement('label');
      const input = document.createElement('input');
      input.type = 'radio';
      input.name = name;
      input.value = value;
      const span = document.createElement('span');
      span.textContent = text;
      label.append(input, span);
      row.append(label);
    });
    set.append(legend, row);
    return set;
  }
  function linuxPicker(list, items) {
    const formats = choice('Package', 'linux-format', FORMATS.filter(([f]) => items.some(a => a.format === f)));
    const gpus = choice('GPU', 'linux-gpu', GPUS.filter(([g]) => items.some(a => a.gpu === g)));
    const link = downloadLink(items[0]);
    const pick = (name, value) => { const input = list.querySelector(`input[name="${name}"][value="${value}"]`); if (input) input.checked = true; };
    const update = () => {
      const format = list.querySelector('input[name="linux-format"]:checked').value;
      list.querySelectorAll('input[name="linux-gpu"]').forEach(input => { input.disabled = !items.some(a => a.format === format && a.gpu === input.value); });
      let gpu = list.querySelector('input[name="linux-gpu"]:checked');
      if (!gpu || gpu.disabled) { gpu = list.querySelector('input[name="linux-gpu"]:not(:disabled)'); if (gpu) gpu.checked = true; }
      link.set(items.find(a => a.format === format && (!gpu || a.gpu === gpu.value)) || items[0]);
    };
    list.append(formats, gpus, link);
    pick('linux-format', items[0].format);
    pick('linux-gpu', items[0].gpu);
    list.addEventListener('change', update);
    update();
  }
  function retry(message) {
    version.textContent = message;
    cards.forEach(card => {
      const list = card.querySelector('[data-assets]');
      list.replaceChildren();
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'asset-retry';
      button.textContent = 'Retry downloads';
      button.addEventListener('click', load);
      list.append(button);
    });
  }
  async function load() {
    version.textContent = 'Finding the latest version…';
    cards.forEach(card => { card.querySelector('[data-assets]').textContent = 'Loading downloads…'; });
    try {
      let release = null;
      if (cached) {
        try {
          const response = await fetch(cached, { cache:'no-cache' });
          if (response.ok) release = await response.json();
        } catch(error) { console.warn('Could not read the cached release:', error); }
      }
      if (!release?.assets?.length) {
        const response = await fetch(endpoint, { headers:{ Accept:'application/vnd.github+json' } });
        if (!response.ok) throw new Error('Release API ' + response.status);
        release = await response.json();
      }
      const assets = { linux:[], windows:[], macos:[] };
      (release.assets || []).forEach(asset => {
        const type = describe(asset.name);
        if (type && /^https:\/\/github\.com\/highercomve\/GhostPen\/releases\/download\//.test(asset.browser_download_url)) {
          assets[type.os].push({ ...type, url:asset.browser_download_url, bytes:asset.size });
        }
      });
      Object.values(assets).forEach(items => items.sort((a,b) => a.priority - b.priority));
      if (!Object.values(assets).some(items => items.length)) throw new Error('No installers found');
      version.textContent = release.tag_name ? 'Latest release · ' + release.tag_name : 'Latest release';
      const appimage = assets.linux.find(asset => asset.label.startsWith('AppImage') && !asset.label.includes('CUDA'));
      const appimageSize = document.querySelector('[data-appimage-size]');
      if (appimage && appimageSize) appimageSize.textContent = size(appimage.bytes);
      cards.forEach(card => {
        const target = card.dataset.downloadOs;
        const list = card.querySelector('[data-assets]');
        list.replaceChildren();
        if (!assets[target].length) {
          const empty = document.createElement('span');
          empty.className = 'asset-loading';
          empty.textContent = 'No download for this platform in the latest release.';
          list.append(empty);
          return;
        }
        if (target === 'linux') return linuxPicker(list, assets.linux);
        const asset = assets[target][0];
        asset.specs.forEach(([title, value]) => {
          const row = document.createElement('div');
          row.className = 'asset-choice';
          const legend = document.createElement('p');
          legend.className = 'asset-legend';
          legend.textContent = title;
          const fixed = document.createElement('div');
          fixed.className = 'asset-fixed';
          fixed.textContent = value;
          row.append(legend, fixed);
          list.append(row);
        });
        list.append(downloadLink(asset));
      });
      const preferred = assets[os][0];
      if (preferred) {
        primary.href = preferred.url;
        primary.firstChild.textContent = 'Download for ' + ({linux:'Linux',windows:'Windows',macos:'macOS'}[os]) + ' ';
        primary.title = preferred.label + ' · ' + size(preferred.bytes);
      }
    } catch(error) {
      console.warn('Could not load GhostPen release assets:', error);
      primary.href = '#download';
      retry('Downloads are temporarily unavailable');
    }
  }
  load();
})();
