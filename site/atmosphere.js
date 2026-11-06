// Preview-only background layer. The site's content and interactions are unchanged.
(() => {
  const designs = [
    ['#how-it-works', 'channel', [
      'M-120 560C240 330 420 620 800 540S1250 150 1720 270',
      'M-120 600C240 370 420 660 800 580S1250 190 1720 310',
      'M850-60C1060 80 1280 70 1700 10']],
    ['#agents', 'tide', [
      'M-100 100C200-20 440 250 780 100S1220-50 1710 180',
      'M-100 135C200 15 440 285 780 135S1220-15 1710 215',
      'M-150 510C180 340 380 750 760 580S1250 530 1720 620']],
    ['#features', 'arch', [
      'M-100 40C320 280 400-100 810 60S1250 190 1710 20',
      'M-100 69C320 309 400-71 810 89S1250 219 1710 49',
      'M-100 600C400 320 810 850 1180 540S1530 370 1730 490',
      'M-100 635C400 355 810 885 1180 575S1530 405 1730 525']],
    ['#sharing', 'beacon', [
      'M-100 80C280 240 300-80 750 40S1280 0 1720-70',
      'M-100 540C250 720 450 380 850 570S1280 370 1730 490',
      'M-100 580C250 760 450 420 850 610S1280 410 1730 530',
      'M-100 620C250 800 450 460 850 650S1280 450 1730 570']],
    ['#self-host', 'harbour', [
      'M-100 50C300 210 470-80 820 80S1250 160 1740 0',
      'M900 230C740 130 1230-100 1490 60S1440 330 1140 280S940 110 1320 80',
      'M935 213C795 127 1230-67 1450 78S1410 303 1150 258S990 124 1318 104',
      'M973 195C860 123 1230-30 1410 96S1380 276 1160 235S1040 138 1316 130',
      'M-120 530C250 720 600 440 1020 610S1460 470 1740 530',
      'M-120 565C250 755 600 475 1020 645S1460 505 1740 565']],
    ['.closing', 'horizon', [
      'M-100 300C400 30 600 450 1100 220S1400 250 1730 70',
      'M-100 340C400 70 600 490 1100 260S1400 290 1730 110']]
  ];
  const tracks = [];
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const svgNS = 'http://www.w3.org/2000/svg';
  let paused = false;
  const visible = new Set();
  function addTrack(host, path, duration, phase, response = false, owner = host) {
    const sprite = document.createElement('span');
    sprite.className = 'coastal-sprite' + (response ? ' sprite-response' : '');
    sprite.setAttribute('aria-hidden', 'true');
    host.append(sprite);
    tracks.push({host, path, sprite, duration, phase, owner, animation: null});
  }
  designs.forEach(([selector, name, paths], index) => {
    const section = document.querySelector(selector);
    if (!section) return;
    section.classList.add('atmospheric-section');
    const layer = document.createElement('div');
    layer.className = `section-atmosphere atmosphere-${name}`;
    layer.setAttribute('aria-hidden', 'true');
    layer.innerHTML = `<div class="atmosphere-static"><div class="atmosphere-light"></div><div class="atmosphere-beam"></div>
      <svg class="coastal-art" viewBox="0 0 1600 700" preserveAspectRatio="none" focusable="false">
        <defs><linearGradient id="coastal-line-${index}" x1="0" y1="1" x2="1" y2="0"><stop stop-color="#38a88a" stop-opacity=".38"/><stop offset=".38" stop-color="#8c9a8b" stop-opacity=".12"/><stop offset=".72" stop-color="#f5b544" stop-opacity=".48"/><stop offset="1" stop-color="#f5b544" stop-opacity=".08"/></linearGradient></defs>
      </svg></div>`;
    const svg = layer.querySelector('svg');
    paths.forEach(d => {
      const path = document.createElementNS(svgNS, 'path');
      path.setAttribute('d', d);
      path.setAttribute('stroke', `url(#coastal-line-${index})`);
      path.setAttribute('class', 'coastal-contour');
      svg.append(path);
    });
    section.prepend(layer);
    const path = svg.querySelectorAll('.coastal-contour')[name === 'harbour' ? 1 : paths.length - 1];
    addTrack(layer, path, (29 + index * 3) * 1000, index * 5000 + 8000);
  });
  const traffic = document.querySelector('.traffic-diagram');
  if (traffic) {
    const stage = traffic.querySelector('.traffic-stage');
    addTrack(stage, traffic.querySelector('.wire-request'), 6000, 0, false, traffic);
    addTrack(stage, traffic.querySelector('.wire-response'), 7000, 3000, true, traffic);
  }
  // Sample the existing static paths only on layout changes. During motion the
  // browser moves a tiny cached sprite with transform/opacity, not a large SVG.
  function rebuildTracks() {
    tracks.forEach(track => {
      const {host, path, sprite, duration, phase} = track;
      const progress = track.animation?.currentTime ?? phase;
      track.animation?.cancel();
      const box = host.getBoundingClientRect();
      const svg = path.ownerSVGElement;
      const bounds = svg.getBoundingClientRect();
      const view = svg.viewBox.baseVal;
      const sx = bounds.width / view.width, sy = bounds.height / view.height;
      const length = path.getTotalLength();
      const frames = Array.from({length:161}, (_,i) => {
        const p = path.getPointAtLength(length * i / 160);
        const q = path.getPointAtLength(Math.min(length, length * i / 160 + 1));
        const x = bounds.left - box.left + (p.x - view.x) * sx;
        const y = bounds.top - box.top + (p.y - view.y) * sy;
        const angle = Math.atan2((q.y-p.y)*sy,(q.x-p.x)*sx)*180/Math.PI;
        const edgeFade = Math.max(0,Math.min(1,x/90,(box.width-x)/90,y/55,(box.height-y)/55));
        return {offset:i/160,transform:`translate3d(${x-16}px,${y-8}px,0) rotate(${angle}deg)`,opacity:Math.min(i/8,(160-i)/8,1)*edgeFade*.85};
      });
      track.animation = sprite.animate(frames,{duration,iterations:Infinity,easing:'linear'});
      track.animation.pause();
      track.animation.currentTime = progress;
    });
    syncMotion();
  }
  function syncMotion() {
    const stopped = paused || document.hidden || reducedMotion.matches;
    document.documentElement.classList.toggle('motion-suspended',stopped);
    tracks.forEach(track => {
      const active = !stopped && visible.has(track.owner) && track.owner.dataset.paused !== 'true';
      track.sprite.hidden = reducedMotion.matches;
      if (active) track.animation?.play(); else track.animation?.pause();
    });
  }
  const observer = new IntersectionObserver(entries => {
    entries.forEach(({target,isIntersecting}) => {
      if(isIntersecting) visible.add(target); else visible.delete(target);
      target.classList.toggle('motion-in-view',isIntersecting);
    });
    syncMotion();
  });
  const observed = new Set([...tracks.map(t=>t.owner), ...document.querySelectorAll('.glow-frame')]);
  observed.forEach(element => observer.observe(element));
  let resizeTimer;
  const resizeObserver = new ResizeObserver(() => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(rebuildTracks,120);
  });
  new Set(tracks.map(t=>t.host)).forEach(host=>resizeObserver.observe(host));
  document.addEventListener('visibilitychange',syncMotion);
  reducedMotion.addEventListener('change',syncMotion);
  if(traffic) new MutationObserver(syncMotion).observe(traffic,{attributes:true,attributeFilter:['data-paused']});
  const control = document.createElement('button');
  control.type = 'button';
  control.className = 'atmosphere-motion-control';
  control.setAttribute('aria-pressed', 'false');
  control.textContent = 'Pause animations';
  control.addEventListener('click', () => {
    paused = !paused;
    control.setAttribute('aria-pressed',String(paused));
    control.textContent = paused ? 'Resume animations' : 'Pause animations';
    syncMotion();
  });
  const controls = document.createElement('div');
  controls.className = 'atmosphere-controls';
  controls.append(control);
  document.querySelector('footer').before(controls);
  rebuildTracks();
})();
