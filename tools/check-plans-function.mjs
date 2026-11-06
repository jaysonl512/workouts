// Confirms the deployed "plans" Edge Function computes exactly what the repo's progression.js and programs.js compute.
// Posts sample histories (no stored data is read or written) and compares the answers.
// Run: node tools/check-plans-function.mjs   (uses the project's public anon key, which can only call the function)
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const P = require('../progression.js'), W = require('../plan.js'), G = require('../programs.js');
const URL = 'https://hgqlyhvkwggdioehwdpo.supabase.co/functions/v1/plans';
const ANON = process.env.SUPABASE_ANON_JWT || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImhncWx5aHZrd2dnZGlvZWh3ZHBvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM3MTg1MTcsImV4cCI6MjEwOTI5NDUxN30.lmEl3toYUhC4KlrPMg_uvIaQ3VT-Vx4dIxx7IncwQ_8';
const sets = a => a.map(([w, r]) => ({ w, r }));
const cases = [
  { today: '2026-11-09', settings: {}, sessions: [
    { id: 'b', date: '2026-11-05', entries: [{ id: 'inc-db', sets: sets([[35, 12], [40, 12], [45, 11], [50, 10]]) }, { id: 'pullup', sets: sets([[60, 12], [50, 9], [40, 7]]) }, { id: 'ss-curl', sets: sets([[40, 12], [40, 12], [40, 12]]) }] },
    { id: 'a', date: '2026-11-02', entries: [{ id: 'bench', sets: sets([[55, 8], [60, 8], [65, 8], [70, 5]]) }, { id: 'row', sets: sets([[95, 10], [115, 10], [135, 8], [140, 7]]) }] },
    { id: 'd', date: '2026-11-06', entries: [{ id: 'deadlift', sets: sets([[225, 4], [190, 6], [190, 6]]) }] }] },
  { today: '2027-02-20', settings: { 'inc-db': { structure: 'straight' }, row: { equipment: 'cable', step: 2.5 } }, sessions: [
    { id: 'b', date: '2026-11-05', entries: [{ id: 'inc-db', sets: sets([[35, 12], [40, 12], [45, 11], [50, 10]]) }] }] },
  // A saved program mid-switch, with a moved and a reduced workout.
  { today: '2026-11-05', settings: {}, prog: { config: { ...G.configFor('balanced', 3), startedOn: '2026-11-09', prefs: { use: {}, avoid: ['squat'] } }, past: [{ config: G.defaultConfig(), until: '2026-11-08' }] },
    changes: [{ id: '2026-11-02:upperB:1', change: { week: '2026-11-02', removed: true, source: 'auto' } },
      { id: '2026-11-02:t:fbC:1', change: { week: '2026-11-02', add: true, key: 'fbC', date: '2026-11-06', type: 'lift', name: 'Full Body C (adjusted)', ex: [{ id: 'inc-db', sets: 4 }, { id: 'cable-row', sets: 3 }], source: 'auto' } },
      { id: '2026-11-09:fbA:1', change: { week: '2026-11-09', date: '2026-11-10', source: 'manual' } },
      { id: '2026-11-09:fbB:1', change: { week: '2026-11-09', reduced: true, source: 'readiness' } }],
    sessions: [
      { id: '2026-11-02-upperA', date: '2026-11-02', session: 'upperA', type: 'lift', data: { entries: [{ id: 'bench', sets: sets([[55, 8], [60, 8], [65, 8], [70, 5]]) }] } },
      { id: '2026-11-04-lowerA', date: '2026-11-04', session: 'lowerA', type: 'lift', data: { entries: [{ id: 'squat', sets: sets([[95, 10], [105, 8], [115, 6], [125, 5]]) }] } }] },
];
let ok = true;
for (const [i, c] of cases.entries()) {
  const r = await fetch(URL, { method: 'POST', headers: { Authorization: 'Bearer ' + ANON, 'Content-Type': 'application/json' }, body: JSON.stringify(c) });
  if (!r.ok) { console.log(`case ${i}: HTTP ${r.status} ${await r.text()}`); ok = false; continue; }
  const remote = JSON.stringify(await r.json()), local = JSON.stringify(G.watchPayload(P, { prog: null, changes: [], ...c }));
  console.log(`case ${i}: ${remote === local ? 'same' : 'DIFFERENT'}`);
  if (remote !== local) ok = false;
}
console.log(ok ? 'Deployed function matches the repo.' : 'Deployed function does NOT match the repo: redeploy it (supabase/functions/plans/README.md).');
process.exit(ok ? 0 : 1);
