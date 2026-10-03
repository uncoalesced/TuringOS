// Weather readout in the menu bar and its detail card.

// ─── Weather ────────────────────────────────────────────────────────────────
// WMO weather codes (Open-Meteo): https://open-meteo.com/en/docs

function wxIcon(code, day) {
  if (code === 0) return day ? 'wx-sun' : 'wx-moon';
  if (code <= 2) return day ? 'wx-partly' : 'wx-partly-night';
  if (code === 3) return 'wx-cloud';
  if (code <= 48) return 'wx-fog';
  if (code <= 67 || (code >= 80 && code <= 82)) return 'wx-rain';
  if (code <= 77 || (code >= 85 && code <= 86)) return 'wx-snow';
  if (code >= 95) return 'wx-storm';
  return 'wx-cloud';
}

function wxLabel(code) {
  const table = {
    0: 'Clear', 1: 'Mostly clear', 2: 'Partly cloudy', 3: 'Cloudy',
    45: 'Foggy', 48: 'Foggy',
    51: 'Light drizzle', 53: 'Drizzle', 55: 'Heavy drizzle',
    61: 'Light rain', 63: 'Rain', 65: 'Heavy rain',
    71: 'Light snow', 73: 'Snow', 75: 'Heavy snow',
    80: 'Rain showers', 81: 'Rain showers', 82: 'Violent showers',
    95: 'Thunderstorm', 96: 'Thunderstorm', 99: 'Thunderstorm',
  };
  return table[code] || 'Weather';
}

function renderWeather(w) {
  const btn = $('#weather');
  btn.hidden = !w;
  if (!w) return;
  const icon = wxIcon(w.code, w.day);
  document.querySelectorAll('.wx-use').forEach((u) => u.setAttribute('href', `#${icon}`));
  $('.weather-temp').textContent = `${w.temp}°`;
  $('.weather-city').textContent = w.city || '';
  $('.wc-title').textContent = w.city ? `${w.city} Weather` : 'Weather';
  $('.wc-cond').textContent = wxLabel(w.code);
  $('.wc-temp').textContent = `${w.temp}°`;
  $('.wc-feels').textContent = `${w.feels}°`;
  $('.wc-rain').textContent = `${w.rain} mm`;
  $('.wc-wind').textContent = `${w.wind} km/h`;
  $('.wc-arrow').style.transform = `rotate(${(w.windDir ?? 0) + 180}deg)`;
}

let weatherOpen = false;
function setWeatherOpen(open) {
  weatherOpen = open;
  const card = $('#weather-card');
  $('#weather').setAttribute('aria-expanded', String(open));
  if (open) {
    card.hidden = false;
    card.classList.remove('is-closing');
  } else if (!card.hidden) {
    card.classList.add('is-closing');
    setTimeout(() => { if (weatherOpen === false) card.hidden = true; }, 150);
  }
}

$('#weather').addEventListener('click', () => setWeatherOpen(!weatherOpen));
document.addEventListener('click', (e) => {
  if (weatherOpen && !e.target.closest('#weather, #weather-card')) setWeatherOpen(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && weatherOpen) setWeatherOpen(false);
});
