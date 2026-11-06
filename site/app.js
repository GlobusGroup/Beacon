const tabs = [...document.querySelectorAll('[data-tab]')];
function selectTab(name, focus = false) {
  tabs.forEach(tab => {
    const selected = tab.dataset.tab === name;
    tab.classList.toggle('active', selected);
    tab.setAttribute('aria-selected', selected);
    tab.tabIndex = selected ? 0 : -1;
    document.getElementById(`panel-${tab.dataset.tab}`).hidden = !selected;
    if (selected && focus) tab.focus();
  });
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectTab(tab.dataset.tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (['ArrowRight', 'ArrowDown'].includes(event.key)) next = (index + 1) % tabs.length;
    if (['ArrowLeft', 'ArrowUp'].includes(event.key)) next = (index + tabs.length - 1) % tabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = tabs.length - 1;
    if (next !== undefined) { event.preventDefault(); selectTab(tabs[next].dataset.tab, true); }
  });
});
let toastTimer;
function toast(message) {
  const element = document.getElementById('toast');
  clearTimeout(toastTimer);
  element.textContent = message;
  element.classList.add('visible');
  toastTimer = setTimeout(() => element.classList.remove('visible'), 3500);
}
async function copy(text, message) {
  try { await navigator.clipboard.writeText(text); toast(message); }
  catch { toast(`Copy this: ${text}`); }
}
document.getElementById('copy-command').addEventListener('click', () => copy('beacon register', 'Command copied'));
document.querySelectorAll('[data-copy]').forEach(button => button.addEventListener('click', () => copy(button.dataset.copy, 'Command copied')));
const dialog = document.getElementById('project-dialog');
document.getElementById('add-project').addEventListener('click', () => dialog.showModal());
document.getElementById('close-dialog').addEventListener('click', () => dialog.close());
dialog.addEventListener('click', event => { if (event.target === dialog) { const rect = dialog.getBoundingClientRect(); if (event.clientX < rect.left || event.clientX > rect.right || event.clientY < rect.top || event.clientY > rect.bottom) dialog.close(); } });
document.getElementById('project-form').addEventListener('submit', event => {
  event.preventDefault();
  const input = document.getElementById('project-name');
  const name = input.value.trim();
  const domain = `${name}.test`;
  const rows = [...document.querySelectorAll('#project-list .project-row')];
  if (rows.some(row => row.querySelector('strong').textContent === domain)) { input.setCustomValidity('That one\'s already in the list.'); input.reportValidity(); return; }
  // Like Beacon, hand out the next free port in the range.
  const ports = rows.map(row => parseInt(row.querySelector('.port').textContent.replace(/\D/g, ''), 10));
  const port = Math.max(3100, ...ports) + 1;
  const row = rows[rows.length - 1].cloneNode(true);
  row.querySelector('strong').textContent = domain;
  row.querySelector('.port').textContent = `→ ${port}`;
  row.querySelector('.share-dot')?.remove();
  const badge = row.querySelector('.status-badge');
  badge.textContent = 'Offline';
  badge.classList.add('offline');
  row.querySelector('.row-action').innerHTML = '';
  row.querySelector('.project-menu').setAttribute('aria-label', `Actions for ${domain}`);
  document.getElementById('project-list').append(row);
  dialog.close();
  row.scrollIntoView({block:'nearest', behavior:'instant'});
  toast(`Added ${domain} on port ${port}`);
  event.target.reset();
});
document.getElementById('project-name').addEventListener('input', event => event.target.setCustomValidity(''));

// The ••• menu on each row. Preview only: items describe what Beacon does.
const rowMenu = document.getElementById('row-menu');
let menuOwner = null;
function closeRowMenu() { rowMenu.hidden = true; menuOwner?.setAttribute('aria-expanded', 'false'); menuOwner = null; }
document.getElementById('project-list').addEventListener('click', event => {
  const button = event.target.closest('.project-menu');
  if (!button) return;
  event.stopPropagation();
  if (menuOwner === button) { closeRowMenu(); return; }
  closeRowMenu();
  menuOwner = button;
  button.setAttribute('aria-expanded', 'true');
  const panel = rowMenu.parentElement.getBoundingClientRect();
  const rect = button.getBoundingClientRect();
  rowMenu.hidden = false;
  rowMenu.style.top = `${rect.bottom - panel.top + 4}px`;
  rowMenu.style.right = `${panel.right - rect.right}px`;
  rowMenu.querySelector('button').focus();
});
rowMenu.addEventListener('click', event => {
  const item = event.target.closest('[data-preview-action]');
  if (!item) return;
  const domain = menuOwner?.closest('.project-row').querySelector('strong').textContent;
  closeRowMenu();
  toast(`In the app, this ${item.dataset.previewAction.replaceAll('{d}', domain ?? 'the project')}.`);
});
document.addEventListener('click', event => { if (!rowMenu.hidden && !rowMenu.contains(event.target)) closeRowMenu(); });
document.addEventListener('keydown', event => { if (event.key === 'Escape' && !rowMenu.hidden) { const owner = menuOwner; closeRowMenu(); owner?.focus(); } });

document.querySelectorAll('[data-scroll-to]').forEach(button => button.addEventListener('click', () => {
  document.getElementById(button.dataset.scrollTo).scrollIntoView({block:'center', behavior:matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'});
  selectTab('general', true);
}));

// An explicit pause control for the decorative sharing illustration.
const trafficMotion = document.querySelector('.traffic-motion');
trafficMotion?.addEventListener('click', () => {
  const paused = trafficMotion.getAttribute('aria-pressed') !== 'true';
  trafficMotion.setAttribute('aria-pressed', String(paused));
  trafficMotion.setAttribute('aria-label', paused ? 'Resume traffic animation' : 'Pause traffic animation');
  trafficMotion.querySelector('.traffic-motion-label').textContent = paused ? 'Play' : 'Pause';
  trafficMotion.closest('.traffic-diagram').dataset.paused = String(paused);
});


// Setup steps are a separate tab group from the app mockup.
const setupTabs = [...document.querySelectorAll('[data-setup-step]')];
function selectSetupStep(selected, focus = false) {
  setupTabs.forEach(tab => {
    const active = tab === selected;
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
    const panel = document.getElementById(tab.getAttribute('aria-controls'));
    panel.hidden = !active;
    if (active) panel.scrollTop = 0;
  });
  if (focus) selected.focus({preventScroll:true});
}
setupTabs.forEach((tab,index) => {
  tab.addEventListener('click', () => selectSetupStep(tab));
  tab.addEventListener('keydown', event => {
    let next;
    if (['ArrowRight','ArrowDown'].includes(event.key)) next = (index + 1) % setupTabs.length;
    if (['ArrowLeft','ArrowUp'].includes(event.key)) next = (index + setupTabs.length - 1) % setupTabs.length;
    if (event.key === 'Home') next = 0;
    if (event.key === 'End') next = setupTabs.length - 1;
    if (next !== undefined) { event.preventDefault(); selectSetupStep(setupTabs[next], true); }
  });
});
