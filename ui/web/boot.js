// Sets the graphics level before anything paints. On the bridge
// (turingos-bridged-ws), /boot.js is this file with one line in front that
// defines window.__TURINGOS__; opened from disk or a plain web server that
// line is missing and the page is in sample mode. Order: the user's manual
// choice, then the level the page measured its way down to on this graphics
// path, then the launcher's hint (?gfx=sw.lite, session/turingos-kiosk).
(function () {
  var levels = ['full', 'lite', 'minimal'];
  var hint = null;
  var m = /[?&]gfx=(gpu|sw)\.(full|lite|minimal)\b/.exec(location.search);
  if (m) hint = { path: m[1], tier: m[2] };
  if (window.__TURINGOS__) window.__TURINGOS__.gfx = hint;
  var pick = null;
  try {
    var manual = localStorage.getItem('gfx');
    if (levels.indexOf(manual) !== -1) pick = manual;
    if (!pick && hint) {
      var auto = JSON.parse(localStorage.getItem('gfxAuto') || 'null');
      if (auto && auto.path === hint.path && levels.indexOf(auto.tier) !== -1) pick = auto.tier;
    }
  } catch (e) {}
  document.documentElement.dataset.gfx = pick || (hint && hint.tier) || 'full';
})();
