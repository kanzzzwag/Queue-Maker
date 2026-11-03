// Queue page.
import { initPage } from './common.js';
import { mountQueue } from './queue-view.js';

const ctx = await initPage('queue');
if (ctx) mountQueue(document.getElementById('queue'), { profile: ctx.profile, flags: ctx.flags });
