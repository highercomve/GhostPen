// Illustrative homepage scenes use fixed sample copy, not an AI request.
(() => {
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const demo = document.querySelector('.demo');
  const sample = document.querySelector('.sample-text');
  const stepButtons = [...document.querySelectorAll('.step-button')];
  const playButton = document.querySelector('.demo-play');
  const motionButton = document.querySelector('.motion-toggle');
  const actionButtons = [...document.querySelectorAll('[data-action]')];
  const original = sample.textContent;
  const results = {
    proofread: 'I’ve attached the proposal. Let me know what you think, and we can discuss it tomorrow.',
    professional: 'Please find the proposal attached. I’d welcome your feedback and would be happy to discuss it tomorrow.',
    translate: 'Adjunto la propuesta. Dime qué te parece y podemos hablarlo mañana.'
  };
  let step = 0;
  let action = 'professional';
  let playing = !reducedMotion.matches;
  let motionPaused = reducedMotion.matches;
  let timer;
  const durations = [2400, 2200, 1400, 4200];

  function syncMotion() {
    document.body.classList.toggle('motion-paused', motionPaused);
    motionButton.textContent = motionPaused ? '▷ Play motion' : 'Ⅱ Pause motion';
    motionButton.setAttribute('aria-pressed', String(motionPaused));
    document.querySelectorAll('svg').forEach(svg => {
      if (typeof svg.pauseAnimations === 'function') {
        if (motionPaused) svg.pauseAnimations(); else svg.unpauseAnimations();
      }
    });
  }
  function schedule() {
    clearTimeout(timer);
    if (playing && !motionPaused && !document.hidden) timer = setTimeout(() => setStep((step + 1) % 4), durations[step]);
  }
  function syncPlay() {
    const active = playing && !motionPaused;
    playButton.textContent = active ? 'Ⅱ' : '▷';
    playButton.setAttribute('aria-label', active ? 'Pause walkthrough' : 'Play walkthrough');
  }
  function setStep(next) {
    step = next;
    demo.dataset.step = String(step);
    sample.textContent = step === 3 ? results[action] : original;
    const localStatus = demo.querySelector('[data-local-status]');
    if (localStatus) localStatus.textContent = [
      'Your selection stays on this device.',
      'GhostPen opens on your computer.',
      'The model rewrites locally, using your GPU or CPU.',
      'The result is back in your app. Your data stayed here.'
    ][step];
    stepButtons.forEach((button, index) => {
      if (index === step) button.setAttribute('aria-current', 'step');
      else button.removeAttribute('aria-current');
    });
    // Hidden illustration controls must not receive keyboard focus.
    const menuVisible = step === 1 || step === 2;
    document.querySelector('.ghost-menu').inert = !menuVisible;
    document.querySelector('.ghost-menu').setAttribute('aria-hidden', String(!menuVisible));
    syncPlay();
    schedule();
  }
  stepButtons.forEach((button, index) => button.addEventListener('click', () => {
    playing = false;
    setStep(index);
  }));
  playButton.addEventListener('click', () => {
    if (motionPaused) { motionPaused = false; playing = true; syncMotion(); }
    else playing = !playing;
    syncPlay();
    schedule();
  });
  motionButton.addEventListener('click', () => {
    motionPaused = !motionPaused;
    syncMotion();
    syncPlay();
    schedule();
  });
  reducedMotion.addEventListener('change', event => {
    motionPaused = event.matches;
    syncMotion();
    syncPlay();
    schedule();
  });
  document.addEventListener('visibilitychange', schedule);
  actionButtons.forEach(button => button.addEventListener('click', () => {
    action = button.dataset.action;
    actionButtons.forEach(item => {
      const active = item.dataset.action === action;
      item.classList.toggle('active', active);
      item.setAttribute('aria-pressed', String(active));
    });
    playing = false;
    setStep(3);
  }));

  function wave() {
    return '<div class="wave" aria-hidden="true">' + Array.from({length:29}, (_,i) => `<i style="--height:${12 + (i * 17 % 33)}px;--delay:-${i * .13}s"></i>`).join('') + '</div>';
  }
  const flowVisuals = {
    rewrite: `<div class="scene-top"><span><i class="scene-dot"></i> Email draft</span><span>01 / PROOFREAD</span></div>
      <div class="scene-pair"><div class="scene-line"><small>YOUR SELECTION</small><span class="scene-old">lets make this sentance better.</span></div>
      <div class="scene-action"><b aria-hidden="true">✦</b><span>GhostPen edits on your computer</span><i aria-hidden="true"></i></div>
      <div class="scene-line scene-result"><small>BACK IN YOUR EMAIL</small><span>Let’s make this sentence better.</span></div></div>
      <div class="scene-foot"><span class="scene-check">✓</span> Replaced in place</div>`,
    translate: `<div class="scene-top"><span><i class="scene-dot"></i> Conversation</span><span>02 / TRANSLATE</span></div>
      <div class="scene-chat"><div class="chat-bubble source"><small>ENGLISH · SELECTED</small><span>Could we talk tomorrow?</span></div>
      <div class="chat-transfer"><span aria-hidden="true">↓</span><span>Translated locally</span></div>
      <div class="chat-bubble target"><small>ESPAÑOL · REPLACED</small><span>¿Podemos hablar mañana?</span></div></div>
      <div class="scene-foot"><span class="scene-check">✓</span> Same app, new language</div>`,
    custom: `<div class="scene-top"><span><i class="scene-dot"></i> Your document</span><span>03 / CUSTOM</span></div>
      <div class="custom-stack"><div class="custom-selection"><small>SELECTED SENTENCE</small><span>In light of the fact that…</span></div>
      <div class="custom-command"><b aria-hidden="true">✦</b><span>Make this shorter</span><i aria-hidden="true"></i><small>↵</small></div>
      <div class="custom-answer"><small>GHOSTPEN WRITES BACK</small><span>Because…</span></div></div>
      <div class="scene-foot"><span class="scene-check">✓</span> Your instruction, your words</div>`,
    voice: `<div class="scene-top"><span><i class="scene-dot"></i> Microphone</span><span>04 / DICTATION</span></div>
      <div class="scene-voice"><div class="voice-ring" aria-hidden="true">●</div>${wave()}<div class="voice-transcript"><small>YOUR WORDS, POLISHED</small><span>“Good ideas start with a conversation.”</span></div></div>
      <div class="scene-foot"><span class="scene-check">✓</span> Ready on your clipboard</div>`,
    captions: `<div class="scene-top"><span><i class="scene-dot"></i> System audio</span><span>05 / CAPTIONS</span></div>
      <div class="scene-video"><div class="video-abstract"><span class="video-play" aria-hidden="true">▷</span><span class="video-sound" aria-hidden="true">▁▃▆▂▅▃▁</span></div><div class="subtitle">“Let’s bring that idea to life.”</div></div>
      <div class="scene-foot"><span class="scene-check">✓</span> Transcribed locally with Whisper</div>`,
    image: `<div class="scene-top"><span><i class="scene-dot"></i> Copied image</span><span>06 / EXTRACT</span></div>
      <div class="scene-ocr"><div class="ocr-paper"><small>IMAGE</small><b>Meeting notes</b><span>Good ideas<br>start here.</span><i aria-hidden="true"></i></div><div class="ocr-moving" aria-hidden="true">→</div><div class="ocr-plain"><small>EDITABLE TEXT</small><span>Good ideas<br>start here.</span></div></div>
      <div class="scene-foot"><span class="scene-check">✓</span> Ready to rewrite or translate</div>`
  };
  document.querySelectorAll('[data-visual]').forEach(el => {
    el.innerHTML = flowVisuals[el.dataset.visual];
    el.closest('.feature-card').dataset.kind = el.dataset.visual;
  });
  syncMotion();
  setStep(reducedMotion.matches ? 3 : 0);
})();
