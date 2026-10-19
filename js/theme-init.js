// Loaded in <head> (not a module) so the saved theme applies before first paint.
try {
  var t = localStorage.getItem('theme');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
} catch (e) { /* storage blocked: use system theme */ }
