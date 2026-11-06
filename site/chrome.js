(() => {
  const header = document.querySelector('.site-header');
  const sentinel = document.createElement('span');
  sentinel.className = 'header-sentinel';
  sentinel.setAttribute('aria-hidden','true');
  document.body.prepend(sentinel);
  // One threshold observation, with no scroll handler or per-frame work.
  const observer = new IntersectionObserver(([entry]) => {
    header.classList.toggle('is-stuck', entry.boundingClientRect.top < 0 && !entry.isIntersecting);
  });
  observer.observe(sentinel);
  document.querySelectorAll('main>section+section').forEach(section => {
    const divider = document.createElement('div');
    divider.className = 'section-divider';
    divider.setAttribute('aria-hidden','true');
    divider.innerHTML = '<span class="divider-signal"><i></i><b></b><i></i></span>';
    section.prepend(divider);
  });
})();
