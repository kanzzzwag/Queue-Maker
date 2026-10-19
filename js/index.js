// Queue page.
import { requireProfile, setupHeader, initThemeToggle } from './common.js';
import { mountQueue } from './queue-view.js';

initThemeToggle(document.getElementById('theme'));

const profile = await requireProfile();
if (profile) {
  setupHeader(profile);
  mountQueue(document.getElementById('queue'), { profile });
}
