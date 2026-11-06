// Prints a week of the training schedule from programs.js, for the cloud check-in routines.
// Input: a JSON file {today, prog, changes, sessions} where
//   prog     = the public.programs row as {config, past} (or null: the original plan)
//   changes  = public.schedule_changes rows [{id, change}]
//   sessions = complete public.sessions rows [{id, date, session, type, data}]
// Run: node tools/week.mjs input.json [YYYY-MM-DD]   (the optional date picks the week; default today)
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
require('../plan.js'); const G = require('../programs.js');
const inp = JSON.parse(readFileSync(process.argv[2], 'utf8'));
const today = inp.today, date = process.argv[3] || today;
const s = G.weekSchedule({ prog: inp.prog || null, changes: inp.changes || [], sessions: inp.sessions || [], today, date });
const T = G.TEMPLATES[s.config.template];
console.log(`Program: ${T.name}, ${s.config.lifts} lifts, level ${G.LEVELS[s.config.level]} (volume stage ${s.volume.stage}). Week of ${s.weekStart}.`);
for (const x of s.occs) {
  const n = x.type === 'lift' ? G.exList(s.workouts[x.key], x.ex).length + ' exercises' : (G.RUN_KINDS[x.runKind] || 'Run');
  console.log(`${G.DOW_NAME[G.dow(x.date)]} ${x.date}  ${x.name}${x.optional ? ' (optional)' : ''}  ${n}  ${x.status}${x.reduced ? ', reduced' : ''}${x.done ? ' (' + x.done.id + ')' : ''}`);
}
for (const e of s.extras) console.log(`extra: ${e.date} ${e.name || e.session}`);
for (const w of s.warnings) console.log(`warning: ${w.text}`);
console.log(`Goal: ${s.occs.filter(x => !x.optional).length} workouts; done ${s.occs.filter(x => !x.optional && x.status === 'done').length}.`);
