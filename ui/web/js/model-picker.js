// Model + effort picker for the next agent run or chat.

// ─── Model picker ───────────────────────────────────────────────────────────
// Which model/effort the next agent run or chat uses. Persisted locally.
// Claude agents get the model as TURINGOS_AGENT_MODEL (agent/claude.sh passes
// it to `claude --model`); chat answers use both model and effort.

const MODELS = [
  { id: 'claude-fable-5-1', label: 'Fable 5.1', desc: 'For your toughest challenges' },
  { id: 'claude-opus-5-5', label: 'Opus 5.5', desc: 'Most capable for ambitious work' },
  { id: 'claude-sonnet-5-5', label: 'Sonnet 5.5', desc: 'Most efficient for everyday tasks' },
  { id: 'claude-haiku-4-5', label: 'Haiku 4.5', desc: 'Fastest for quick answers' },
];
const EFFORTS = [
  { id: 'low', label: 'Low' },
  { id: 'medium', label: 'Medium', isDefault: true },
  { id: 'high', label: 'High' },
  { id: 'xhigh', label: 'Extra' },
  { id: 'max', label: 'Max' },
];

let modelChoice = localStorage.getItem('model') || 'claude-sonnet-5-5';
let effortChoice = localStorage.getItem('effort') || 'medium';
if (!MODELS.some((m) => m.id === modelChoice)) modelChoice = 'claude-sonnet-5-5';
if (!EFFORTS.some((e) => e.id === effortChoice)) effortChoice = 'medium';

const modelMenu = $('#model-menu');
const modelPickerButton = $('#model-picker-button');
let modelMenuOpen = false;

function renderModelPickerButton() {
  $('#model-picker-label').textContent = MODELS.find((m) => m.id === modelChoice)?.label || modelChoice;
  $('#model-picker-effort-label').textContent = EFFORTS.find((e) => e.id === effortChoice)?.label || effortChoice;
}

function renderModelMenu() {
  const modelsPage = $('#model-menu-page-models');
  modelsPage.replaceChildren(...MODELS.map((m) => {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'model-option';
    el.setAttribute('role', 'menuitemradio');
    el.setAttribute('aria-checked', String(m.id === modelChoice));
    el.innerHTML = `
      <span class="model-option-text">
        <span class="model-option-name">${m.label}</span>
        <span class="model-option-desc">${m.desc}</span>
      </span>
      ${m.id === modelChoice ? '<svg class="icon" aria-hidden="true"><use href="#ic-check" /></svg>' : ''}
    `;
    el.addEventListener('click', () => {
      modelChoice = m.id;
      localStorage.setItem('model', modelChoice);
      renderModelPickerButton();
      renderModelMenu();
      closeModelMenu();
    });
    return el;
  }));

  const divider = document.createElement('hr');
  divider.className = 'model-menu-divider';
  const effortRow = document.createElement('button');
  effortRow.type = 'button';
  effortRow.className = 'model-menu-more';
  effortRow.innerHTML = `<span>Effort</span><span class="model-menu-more-value">${EFFORTS.find((e) => e.id === effortChoice)?.label}<svg class="icon" aria-hidden="true"><use href="#ic-chevron-right" /></svg></span>`;
  effortRow.addEventListener('click', () => showModelMenuPage('effort'));

  const moreDivider = document.createElement('hr');
  moreDivider.className = 'model-menu-divider';
  const moreRow = document.createElement('button');
  moreRow.type = 'button';
  moreRow.className = 'model-menu-more';
  moreRow.innerHTML = '<span>More models</span><svg class="icon" aria-hidden="true"><use href="#ic-chevron-right" /></svg>';
  moreRow.addEventListener('click', () => setHint('More models coming soon'));

  modelsPage.append(divider, effortRow, moreDivider, moreRow);

  const effortPage = $('#model-menu-page-effort');
  const existingOptions = effortPage.querySelectorAll('.effort-option');
  existingOptions.forEach((el) => el.remove());
  effortPage.append(...EFFORTS.map((eff) => {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'effort-option';
    el.setAttribute('role', 'menuitemradio');
    el.setAttribute('aria-checked', String(eff.id === effortChoice));
    el.innerHTML = `
      <span class="model-option-text">${eff.label}</span>
      ${eff.isDefault ? '<span class="effort-default-tag">Default</span>' : ''}
      ${eff.id === effortChoice ? '<svg class="icon" aria-hidden="true"><use href="#ic-check" /></svg>' : ''}
    `;
    el.addEventListener('click', () => {
      effortChoice = eff.id;
      localStorage.setItem('effort', effortChoice);
      renderModelPickerButton();
      renderModelMenu();
      showModelMenuPage('models');
      closeModelMenu();
    });
    return el;
  }));
}

function showModelMenuPage(page) {
  $('#model-menu-page-models').hidden = page !== 'models';
  $('#model-menu-page-effort').hidden = page !== 'effort';
}

function openModelMenu() {
  renderModelMenu();
  showModelMenuPage('models');
  modelMenu.hidden = false;
  modelMenuOpen = true;
  modelPickerButton.setAttribute('aria-expanded', 'true');
}

function closeModelMenu() {
  modelMenu.hidden = true;
  modelMenuOpen = false;
  modelPickerButton.setAttribute('aria-expanded', 'false');
}

modelPickerButton.addEventListener('click', () => (modelMenuOpen ? closeModelMenu() : openModelMenu()));
$('#model-menu-back').addEventListener('click', () => showModelMenuPage('models'));
document.addEventListener('click', (e) => {
  if (modelMenuOpen && !e.target.closest('.model-picker')) closeModelMenu();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && modelMenuOpen) closeModelMenu();
});

renderModelPickerButton();
