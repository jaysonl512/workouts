// Tests for programs.js (training programs, schedules, recovery and mid-week switching).
// Run: node --test tests/*.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const W = require('../plan.js');
const Prog = require('../progression.js');
const P = require('../programs.js');

/* ---------- fixtures ---------- */
// A logged lift with every planned set done (weight 50, 8 reps) unless sets are given.
function lift(key, date, opts = {}) {
  const S = W.PLAN.sessions[key] || { ex: [] };
  const ex = opts.ex || S.ex.map(e => [e.id, e.sets]);
  return { id: date + '-' + key, date, session: key, type: 'lift', name: opts.name || (S.name || key), occ: opts.occ, uid: opts.uid, reduced: opts.reduced,
    entries: ex.map(([id, n]) => ({ id, sets: Array.from({ length: n }, () => ({ w: 50, r: 8 })) })) };
}
const run = (date, key = 'run') => ({ id: date + '-' + key, date, session: key, type: 'run', run: { distanceKm: 5, minutes: 30 } });
const def = () => ({ config: P.defaultConfig() });
const MON = '2026-11-02', TUE = '2026-11-03', WED = '2026-11-04', THU = '2026-11-05', FRI = '2026-11-06', SAT = '2026-11-07';
const NEXT = '2026-11-09';
const sched = (o) => P.weekSchedule({ changes: [], sessions: [], ...o });
const byKey = (s, k) => s.occs.find(x => x.key === k);

/* ---------- weekly volume ---------- */
test('V1 weekly volume per program (sets and credits kept separate)', () => {
  const tot = (t, n, level) => {
    const c = { ...P.configFor(t, n), level }, st = level === 'returning' ? 'r1' : level === 'higher' ? 'hi' : 'reg';
    const ws = P.workoutsFor(c, { stage: st, fresh: {} }); let sets = 0; const cr = {};
    Object.values(ws).forEach(w => { const v = P.plannedVolume(w); sets += v.sets; for (const m in v.credits) cr[m] = Math.round(((cr[m] || 0) + v.credits[m]) * 10) / 10 });
    return { sets, cr };
  };
  const expect = { 'upperLower 4': [50, 82, 103], 'balanced 3': [33, 49, 63], 'ppl 3': [29, 49, 63], 'ppl 4': [38, 58, 76], 'ppl 5': [44, 67, 88], 'ppl 6': [46, 68, 88], 'strengthRun 2': [25, 37, 46], 'strengthRun 3': [27, 41, 52] };
  for (const [k, v] of Object.entries(expect)) { const [t, n] = k.split(' '); assert.deepEqual(['returning', 'regular', 'higher'].map(l => tot(t, +n, l).sets), v, k) }
  assert.deepEqual(tot('upperLower', 4, 'regular').cr, { chest: 11, back: 15.5, shoulders: 13, triceps: 12, biceps: 12, quads: 13, glutes: 12.5, hamstrings: 10.5, calves: 7, core: 6 });
  assert.deepEqual(tot('balanced', 3, 'regular').cr, { chest: 8, back: 10.5, shoulders: 9, triceps: 7.5, biceps: 6.5, quads: 8, glutes: 9, hamstrings: 6.5, calves: 3, core: 4 });
});

test('V2 volume attribution: compound split, warm-ups excluded, alternatives count as their slot, any program', () => {
  const s = { date: MON, type: 'lift', entries: [
    { id: 'bench', sets: [{ w: 45, r: 8, wu: true }, { w: 95, r: 8 }, { w: 105, r: 6 }] },          // 2 working sets
    { id: 'squat~leg-press', sets: [{ w: 200, r: 10 }, { w: 200, r: 10 }, { w: 0, r: 0 }] },       // empty set ignored
    { id: 'deadlift', sets: [{ w: 225, r: 5 }] }] };
  const v = P.volumeOf([s]);
  assert.equal(v.sets, 5);
  assert.deepEqual(v.credits, { chest: 2, back: 0.5, shoulders: 1, triceps: 1, biceps: 0, quads: 2, glutes: 2, hamstrings: 1, calves: 0, core: 0 });
});

/* ---------- schedules ---------- */
test('S1 current plan stays exactly as it was and warns about the close leg days', () => {
  const s = sched({ prog: def(), today: '2026-11-08', weekStart: NEXT });
  assert.deepEqual(s.occs.map(x => [P.DOW_NAME[P.dow(x.date)], x.key]), [['Mon', 'upperA'], ['Tue', 'run'], ['Wed', 'lowerA'], ['Thu', 'upperB'], ['Fri', 'lowerB'], ['Sat', 'run2']]);
  assert.ok(s.warnings.some(w => w.type === 'spacing' && w.group === 'legs'));
  assert.equal(P.weekSchedule({ prog: null, changes: [], sessions: [], today: '2026-11-08', weekStart: NEXT }).occs.length, 6, 'no stored program = current plan');
});

test('S2 two demanding leg sessions too close warn, but the change is allowed', () => {
  const prog = { config: P.configFor('upperLower', 4) };
  const ok = sched({ prog, today: '2026-11-08', weekStart: NEXT });
  assert.deepEqual(ok.warnings, []);
  const lb = byKey(ok, 'lowerB');
  const moved = sched({ prog, today: '2026-11-08', weekStart: NEXT, changes: [{ id: lb.occ, change: { week: NEXT, date: '2026-11-11', source: 'manual' } }] });
  assert.equal(byKey(moved, 'lowerB').date, '2026-11-11');
  assert.ok(moved.warnings.some(w => w.type === 'spacing' && w.group === 'legs' && /1 day apart/.test(w.text)));
});

test('S3 moving a leg workout keeps its occurrence id and its matching session', () => {
  const prog = { config: P.configFor('upperLower', 4) };
  const la = byKey(sched({ prog, today: MON, weekStart: MON }), 'lowerA');
  const ch = [{ id: la.occ, change: { week: MON, date: WED, source: 'manual' } }];
  const s = sched({ prog, today: THU, weekStart: MON, changes: ch, sessions: [lift('lowerA', WED, { occ: la.occ })] });
  const x = byKey(s, 'lowerA');
  assert.equal(x.occ, la.occ); assert.equal(x.date, WED); assert.equal(x.movedFrom, TUE); assert.equal(x.status, 'done'); assert.ok(x.manual);
});

test('S4 rescheduling after the week started: past days stay, only the moved workout changes', () => {
  const prog = def(), base = sched({ prog, today: WED, weekStart: MON, sessions: [lift('upperA', MON)] });
  const ub = byKey(base, 'upperB');
  const s = sched({ prog, today: WED, weekStart: MON, sessions: [lift('upperA', MON)], changes: [{ id: ub.occ, change: { week: MON, date: SAT, source: 'manual' } }] });
  assert.equal(byKey(s, 'upperA').status, 'done');
  assert.equal(byKey(s, 'run').status, 'missed');
  assert.equal(byKey(s, 'upperB').date, SAT);
  assert.equal(byKey(s, 'lowerA').date, WED);
});

test('S5 switching from four lifting days to three', () => {
  const prog = def(), hist = [lift('upperA', '2026-10-26'), lift('lowerA', '2026-10-28'), lift('upperB', '2026-10-29'), lift('lowerB', '2026-10-30')];
  const r = P.planSwitch({ prog, next: P.configFor('balanced', 3, prog.config), changes: [], sessions: hist, today: MON });
  assert.equal(r.added.filter(x => x.type === 'lift').length, 3);
  assert.deepEqual(r.added.filter(x => x.type === 'lift').map(x => x.date), [MON, WED, FRI]);
  assert.deepEqual(r.nextWeek.filter(x => x.type === 'lift').map(x => x.key), ['fbA', 'fbB', 'fbC']);
  assert.equal(r.prog.config.startedOn, NEXT);
  assert.equal(r.prog.past[0].until, '2026-11-08');
  // nothing in the history changed
  assert.equal(hist.length, 4); assert.equal(hist[0].entries[0].sets.length, 4);
});

/* ---------- training levels ---------- */
test('L1 Returning level: fewer sets, pyramid starts one set later, one back-off, optional accessories out', () => {
  const c = { ...P.configFor('upperLower', 4), level: 'returning' };
  const w = P.workoutsFor(c, { stage: 'r1', fresh: {} });
  const ex = id => Object.values(w).flatMap(x => x.ex).find(e => e.id === id);
  assert.deepEqual(ex('bench').prog.pattern, [8, 6, 5]); assert.equal(ex('bench').sets, 3);
  assert.equal(ex('deadlift').prog.backSets, 1); assert.equal(ex('deadlift').sets, 2);
  assert.equal(ex('row').sets, 3); assert.equal(ex('pushdown').sets, 2);
  assert.equal(ex('lunge'), undefined); assert.equal(ex('front-sq'), undefined);
  assert.equal(P.groupLoads(P.plannedVolume(w.lowerA).credits).legs, 9.5);
});

test('L2 Returning ramp: two good weeks per stage, poor weeks hold, time alone never adds volume', () => {
  const prog = { config: { ...P.configFor('upperLower', 4), level: 'returning', levelSince: '2026-10-05' } };
  const week = ws => [lift('upperA', ws), lift('lowerA', P.addDays(ws, 1)), lift('upperB', P.addDays(ws, 3))].map(s => ({ ...s, entries: s.entries.map(e => ({ ...e, sets: e.sets.slice(0, 2) })) }));
  const vol = (sessions, changes = []) => P.volumeFor(prog, { sessions, changes }, '2026-11-02').stage;
  assert.equal(vol([]), 'r1', 'four empty weeks: still stage 1');
  assert.equal(vol([...week('2026-10-05'), ...week('2026-10-12')]), 'r2');
  assert.equal(vol([...week('2026-10-05'), ...week('2026-10-12'), ...week('2026-10-19'), ...week('2026-10-26')]), 'reg');
  const sore = [{ id: 'chk:2026-10-13', change: { readiness: 'very' } }];
  assert.equal(vol([...week('2026-10-05'), ...week('2026-10-12')], sore), 'r1', 'a very sore week holds');
  const held = { config: { ...prog.config, rampHold: '2026-10-12' } };
  assert.equal(P.volumeFor(held, { sessions: [...week('2026-10-05'), ...week('2026-10-12'), ...week('2026-10-19')], changes: [] }, '2026-11-02').stage, 'r1', 'hold stops counting');
});

test('L3 a muscle group not trained for 3+ weeks starts at returning sets, even at Regular', () => {
  const prog = { config: P.configFor('upperLower', 4) };
  // upper body every week since September, legs once on Sept 1
  const hist = [lift('lowerA', '2026-09-01')];
  for (let d = '2026-09-03'; d < '2026-11-09'; d = P.addDays(d, 7)) hist.push(lift('upperA', d));
  const v = P.volumeFor(prog, { sessions: hist, changes: [] }, NEXT);
  assert.equal(v.fresh.legs, true); assert.equal(v.fresh.push, false);
  const w = P.workoutsFor(prog.config, v);
  assert.deepEqual(w.lowerA.ex.find(e => e.id === 'squat').prog.pattern, [8, 6, 5]);
  assert.deepEqual(w.upperA.ex.find(e => e.id === 'bench').prog.pattern, [10, 8, 6, 5]);
});

/* ---------- readiness and reduced workouts ---------- */
test('R1 reducing volume: optional accessories out, straight sets -1, one back-off fewer, pyramids untouched', () => {
  const w = P.classicWorkouts();
  assert.deepEqual(P.reduceWorkout(w.lowerB), [{ id: 'deadlift', sets: 2 }, { id: 'hip-thrust', sets: 2 }, { id: 'leg-ext', sets: 2 }, { id: 'calf-seat', sets: 2 }, { id: 'knee-raise', sets: 2 }, { id: 'plank', sets: 2 }]);
  assert.deepEqual(P.reduceWorkout(w.upperA).map(e => [e.id, e.sets]), [['bench', 4], ['row', 3], ['ohp-db', 2], ['pulldown', 2], ['pushdown', 2]]);
});

test('R2 a reduced workout never counts as failed and never earns progression from fewer sets', () => {
  const c = Prog.configFor(W.EXMAP.row, {});
  const first = Prog.planFor(c, [], MON);                                  // first time
  const normal = { date: MON, sets: [{ w: 100, r: 10 }, { w: 100, r: 10 }, { w: 100, r: 10 }, { w: 100, r: 10 }], prog: { ...first.state, W: 100, T: 10, planned: Array(4).fill({ w: 100, r: 10, k: 'work' }) } };
  const after = Prog.planFor(c, [normal], WED);                            // Met -> progresses
  // Reduced: 3 of 4 planned sets, all at target. Saved plan still lists all 4 sets.
  const reduced = { date: WED, sets: after.sets.slice(0, 3).map(x => ({ w: x.w, r: x.r })), prog: after.state };
  const next = Prog.planFor(c, [reduced, normal], FRI);
  assert.equal(next.last, 'incomplete');
  assert.deepEqual(next.sets.map(x => [x.w, x.r]), after.sets.map(x => [x.w, x.r]), 'same targets as before the reduced day');
  assert.equal(next.sets.length, 4, 'back to normal volume');
  assert.equal(next.state.miss || 0, after.state.miss || 0, 'missed streak unchanged');
});

test('R3 readiness: very sore suggests a later day that is clear of the sore area, else reduce', () => {
  const prog = { config: P.configFor('balanced', 3) };
  const s = sched({ prog, today: MON, weekStart: MON });
  const r = P.readiness(s, byKey(s, 'fbA').occ, 'very', MON, 'legs');
  assert.equal(r.recommend, 'move');
  assert.equal(r.moveTo, '2026-11-08', 'Tue is too soon for sore legs; Thu and Sat sit next to the other leg days');
  const ul = { config: P.configFor('upperLower', 4) };
  const s2 = sched({ prog: ul, today: TUE, weekStart: MON, sessions: [lift('upperA', MON)] });
  const r2 = P.readiness(s2, byKey(s2, 'lowerA').occ, 'very', TUE, 'legs');
  assert.equal(r2.moveTo, null, 'every later day would crowd Lower B');
  assert.equal(r2.recommend, 'reduce');
  assert.equal(P.readiness(s2, byKey(s2, 'lowerA').occ, 'sore', TUE).recommend, 'start');
  assert.equal(P.readiness(s2, byKey(s2, 'lowerA').occ, 'ready', TUE).recommend, null);
});

test('R4 skipping a workout leaves progression exactly where it was', () => {
  const c = Prog.configFor(W.EXMAP.squat, {});
  const h = [{ date: '2026-10-28', sets: [{ w: 95, r: 10 }, { w: 105, r: 8 }, { w: 115, r: 6 }, { w: 125, r: 5 }] }];
  const plan1 = Prog.planFor(c, h, WED);
  const prog = def(), s = sched({ prog, today: WED, weekStart: MON, changes: [{ id: `${MON}:lowerA:1`, change: { week: MON, skipped: true, source: 'readiness' } }] });
  assert.equal(byKey(s, 'lowerA').status, 'skipped');
  // a skip creates no session, so the next plan comes from the same history
  assert.deepEqual(Prog.planFor(c, h, FRI).sets, plan1.sets);
});

/* ---------- mid-week switching ---------- */
const thursdaySwitch = (extra = {}) => P.planSwitch({ prog: def(), next: P.configFor('balanced', 3, P.defaultConfig()), changes: [], sessions: [lift('upperA', MON), lift('lowerA', WED)], today: THU, ...extra });

test('M1 the Thursday example: Upper/Lower to Full Body after Upper A and Lower A', () => {
  const r = thursdaySwitch();
  assert.equal(r.before.sets, 35);
  assert.deepEqual(r.before.credits, { chest: 4, back: 7, shoulders: 5, triceps: 5.5, biceps: 5.5, quads: 7, glutes: 5, hamstrings: 6, calves: 4, core: 0 });
  assert.deepEqual(r.target, { chest: 8, back: 10.5, shoulders: 9, triceps: 7.5, biceps: 6.5, quads: 8, glutes: 9, hamstrings: 6.5, calves: 3, core: 4 });
  const fri = r.added.find(x => x.type === 'lift');
  assert.equal(fri.date, FRI); assert.equal(fri.key, 'fbC'); assert.equal(fri.name, 'Full Body C (adjusted)');
  assert.deepEqual(fri.ex, [{ id: 'inc-db', sets: 4 }, { id: 'cable-row', sets: 3 }, { id: 'rear', sets: 2 }]);
  assert.deepEqual(fri.dropped.map(d => d.id).sort(), ['calf-st', 'hip-thrust', 'leg-ext']);
  assert.equal(r.added.filter(x => x.type === 'lift').length, 1);
  assert.equal(r.days.find(d => d.date === THU).note, 'Not a lifting day in the new program');
  assert.equal(r.after.sets, 44);
  assert.deepEqual(r.after.credits, { chest: 8, back: 10, shoulders: 9, triceps: 7.5, biceps: 7, quads: 7, glutes: 5, hamstrings: 6, calves: 4, core: 0 });
  assert.deepEqual(r.gaps, [{ muscle: 'glutes', short: 4 }]);
  assert.deepEqual(r.replaced.sort(), [`${MON}:lowerB:1`, `${MON}:run2:1`, `${MON}:upperB:1`]);
  assert.deepEqual(r.nextWeek.filter(x => x.type === 'lift').map(x => [x.date, x.key]), [['2026-11-09', 'fbA'], ['2026-11-11', 'fbB'], ['2026-11-13', 'fbC']]);
  // the saved changes rebuild the same week
  const s = P.weekSchedule({ prog: r.prog, changes: r.rows, sessions: [lift('upperA', MON), lift('lowerA', WED)], today: THU, weekStart: MON });
  assert.deepEqual(s.occs.filter(x => x.status !== 'done' && x.status !== 'missed').map(x => [x.date, x.name]), [[FRI, 'Full Body C (adjusted)'], [SAT, 'Long run']]);
});

test('M2 same switch on Tue/Thu/Sat days: Saturday would only have 5 useful sets, so it stays rest', () => {
  const r = thursdaySwitch({ next: { ...P.configFor('balanced', 3, P.defaultConfig()), days: [2, 4, 6], runs: [] } });
  const lifts = r.added.filter(x => x.type === 'lift');
  assert.deepEqual(lifts.map(x => [x.date, x.key]), [[THU, 'fbC']]);
  assert.match(r.days.find(d => d.date === SAT).note, /Nothing useful/);
});

test('M3 a week where no more workouts are needed', () => {
  const r = P.planSwitch({ prog: def(), next: P.configFor('balanced', 3, P.defaultConfig()), changes: [],
    sessions: [lift('upperA', MON), lift('lowerA', WED), lift('upperB', THU), lift('lowerB', FRI)], today: SAT });
  assert.equal(r.added.filter(x => x.type === 'lift').length, 0);
  assert.deepEqual(r.gaps, []);
});

test('M4 recovery spacing and soreness in a switch', () => {
  const sore = thursdaySwitch({ sore: 'upper' });
  assert.equal(sore.added.filter(x => x.type === 'lift').length, 0, 'very sore upper body blocks Friday upper work, and legs are still recovering');
  const prior = [lift('upperA', '2026-10-26'), lift('lowerA', '2026-10-28'), lift('upperB', '2026-10-29'), lift('lowerB', '2026-10-30')];
  // a long run the day before blocks leg work: Friday long run, Saturday lift has no leg exercises
  const r = P.planSwitch({ prog: def(), next: { ...P.configFor('balanced', 3, P.defaultConfig()), days: [1, 3, 6], runs: [{ dow: 5, kind: 'long' }] }, changes: [],
    sessions: [...prior, lift('upperA', MON)], today: TUE });
  const legs = ['squat', 'deadlift', 'hip-thrust', 'leg-curl', 'lunge', 'leg-ext', 'calf-st'];
  const sat = r.added.find(x => x.date === SAT && x.type === 'lift');
  assert.ok(!sat || (sat.ex && !sat.ex.some(e => legs.includes(e.id))), 'no leg exercises the day after a long run');
  // with an easy run on Friday, Saturday gets the leg work
  const r2 = P.planSwitch({ prog: def(), next: { ...P.configFor('balanced', 3, P.defaultConfig()), days: [1, 3, 6], runs: [{ dow: 5, kind: 'easy' }] }, changes: [],
    sessions: [...prior, lift('upperA', MON)], today: TUE });
  const sat2 = r2.added.find(x => x.date === SAT && x.type === 'lift');
  assert.ok(sat2 && P.exList(P.workoutsFor(r2.prog.config, { stage: 'reg', fresh: {} })[sat2.key], sat2.ex).some(e => legs.includes(e.id)));
});

test('M5 no cramming: at most ceil(lifts x days left / 7) workouts and never two demanding sessions too close', () => {
  const r = P.planSwitch({ prog: def(), next: P.configFor('ppl', 6, P.defaultConfig()), changes: [], sessions: [], today: THU });
  const lifts = r.added.filter(x => x.type === 'lift');
  assert.ok(lifts.length <= Math.ceil(6 * 4 / 7));
  assert.deepEqual(r.warnings.filter(w => w.type === 'spacing'), []);
});

test('M6 manually scheduled workouts are kept and shown as conflicts; only automatic ones are replaced', () => {
  const prog = def(), ub = `${MON}:upperB:1`;
  const changes = [{ id: ub, change: { week: MON, date: SAT, source: 'manual' } }];
  const r = P.planSwitch({ prog, next: P.configFor('balanced', 3, prog.config), changes, sessions: [lift('upperA', MON), lift('lowerA', WED)], today: THU });
  assert.deepEqual(r.conflicts.map(c => [c.occ, c.keep]), [[ub, true]]);
  assert.ok(r.kept.includes(ub)); assert.ok(!r.replaced.includes(ub)); assert.ok(r.replaced.includes(`${MON}:lowerB:1`));
  const r2 = P.planSwitch({ prog, next: P.configFor('balanced', 3, prog.config), changes, sessions: [lift('upperA', MON), lift('lowerA', WED)], today: THU, keep: { [ub]: false } });
  assert.ok(r2.replaced.includes(ub));
});

test('M7 start the new program now instead', () => {
  const r = thursdaySwitch({ startNow: true });
  assert.equal(r.prog.config.startedOn, MON);
  const s = P.weekSchedule({ prog: r.prog, changes: r.rows, sessions: [lift('upperA', MON), lift('lowerA', WED)], today: THU, weekStart: MON });
  assert.deepEqual(s.occs.filter(x => x.type === 'lift').map(x => x.key), ['fbA', 'fbB', 'fbC']);
  assert.equal(s.extras.length, 2, 'the completed old-program workouts are kept as extras');
});

/* ---------- running ---------- */
test('N1 runs: easy runs never warn; long runs and intervals do next to demanding leg days', () => {
  const ul = P.configFor('upperLower', 4);
  const w = runs => sched({ prog: { config: { ...ul, runs } }, today: '2026-11-08', weekStart: NEXT }).warnings.filter(x => x.type === 'run');
  assert.deepEqual(w([{ dow: 3, kind: 'easy' }, { dow: 4, kind: 'easy' }]), []);
  assert.equal(w([{ dow: 4, kind: 'long' }]).length, 1);                     // Thu long run, Fri Lower B
  assert.equal(w([{ dow: 3, kind: 'intervals' }]).length, 1);                // Wed intervals after Tue Lower A
  assert.equal(w([{ dow: 3, kind: 'long' }]).length, 0);                     // Wed long run before Thu Upper B
});

/* ---------- preferences ---------- */
test('F1 exercise preferences carry into every program', () => {
  const base = { ...P.defaultConfig(), prefs: { use: {}, avoid: ['squat'] } };
  for (const [t, n] of [['balanced', 3], ['ppl', 3], ['strengthRun', 2], ['upperLower', 4]]) {
    const c = P.configFor(t, n, base), w = P.workoutsFor(c, { stage: 'reg', fresh: {} });
    const sq = Object.values(w).flatMap(x => x.ex).find(e => e.id === 'squat');
    assert.equal(sq.use, 'squat~leg-press', t);
  }
  const c2 = P.configFor('ppl', 3, { ...P.defaultConfig(), prefs: { use: { squat: 'squat~hack-squat' }, avoid: [] } });
  assert.equal(P.workoutsFor(c2, { stage: 'reg', fresh: {} }).legsA.ex[0].use, 'squat~hack-squat');
  const c3 = P.configFor('ppl', 3, { ...P.defaultConfig(), prefs: { use: {}, avoid: ['calf-st', 'calf-st~leg-press-calf-raise', 'calf-st~smith-calf-raise'] } });
  assert.ok(!P.workoutsFor(c3, { stage: 'reg', fresh: {} }).legsA.ex.some(e => e.id === 'calf-st'), 'no allowed alternative: left out');
});

test('F2 your own set counts and added exercises stay', () => {
  const c = { ...P.configFor('upperLower', 4), edits: { upperA: { sets: { row: 5 }, remove: ['db-curl'], add: [{ id: 'lat-raise', sets: 3 }] } } };
  const ua = P.workoutsFor(c, { stage: 'reg', fresh: {} }).upperA;
  assert.equal(ua.ex.find(e => e.id === 'row').sets, 5);
  assert.ok(!ua.ex.some(e => e.id === 'db-curl'));
  assert.equal(ua.ex.find(e => e.id === 'lat-raise').sets, 3);
});

/* ---------- history and progression across programs ---------- */
test('H1 exercise history carries across programs, including a different set count', () => {
  const hist = [{ id: 'x', date: '2026-10-28', session: 'upperA', type: 'lift', entries: [{ id: 'bench', sets: [{ w: 95, r: 10 }, { w: 100, r: 8 }, { w: 105, r: 6 }, { w: 110, r: 5 }] }, { id: 'row', sets: Array(4).fill({ w: 100, r: 8 }) }] }];
  const classic = P.plansFor(Prog, P.classicWorkouts(), { sessions: hist, settings: {}, today: MON }).upperA;
  const fb = P.plansFor(Prog, P.workoutsFor(P.configFor('balanced', 3), { stage: 'reg', fresh: {} }), { sessions: hist, settings: {}, today: MON }).fbA;
  assert.deepEqual(fb.bench.sets, classic.bench.sets, 'same pyramid, same targets');
  assert.equal(fb.row.sets.length, 3); assert.equal(classic.row.sets.length, 4);
  assert.equal(fb.row.sets[0].w, classic.row.sets[0].w, 'same weight with fewer sets');
  const ret = P.plansFor(Prog, P.workoutsFor({ ...P.configFor('balanced', 3), level: 'returning' }, { stage: 'r1', fresh: {} }), { sessions: hist, settings: {}, today: MON }).fbA;
  assert.deepEqual(ret.bench.sets.slice(-1), classic.bench.sets.slice(-1), 'returning pyramid keeps the top set');
  assert.equal(ret.bench.sets.length, 3);
});

/* ---------- identity, duplicates and the Watch ---------- */
test('D1 a moved workout logged on the old day by an out-of-date Watch counts once', () => {
  const prog = def(), la = `${MON}:lowerA:1`;
  const changes = [{ id: la, change: { week: MON, date: THU, source: 'manual' } }];
  const s = sched({ prog, today: FRI, weekStart: MON, changes, sessions: [lift('lowerA', WED, { occ: la, uid: 'w1' })] });
  assert.equal(byKey(s, 'lowerA').status, 'done'); assert.equal(s.extras.length, 0);
});

test('D2 repeated workouts of the same type: the second is an extra, never a duplicate of the first', () => {
  const prog = def();
  const s = sched({ prog, today: FRI, weekStart: MON, sessions: [lift('upperA', MON, { occ: `${MON}:upperA:1`, uid: 'a' }), { ...lift('upperA', THU, { uid: 'b' }) }] });
  assert.equal(byKey(s, 'upperA').done.uid, 'a');
  assert.equal(s.extras.length, 1);
  // old sessions without occurrence ids still match by workout, first come first served
  const s2 = sched({ prog, today: FRI, weekStart: MON, sessions: [lift('upperA', MON), lift('upperA', THU)] });
  assert.equal(byKey(s2, 'upperA').done.date, MON); assert.equal(s2.extras.length, 1);
});

test('D3 a session id taken by a different workout gets the next free key; the same workout keeps its id', () => {
  const taken = new Set(['2026-11-05-upperA']);
  assert.equal(P.rekey({ date: THU, session: 'upperA', uid: 'b' }, { status: 'complete', uid: 'a' }, taken), 'upperA~2');
  assert.equal(P.rekey({ date: THU, session: 'upperA', uid: 'a' }, { status: 'complete', uid: 'a' }, taken), null);
  assert.equal(P.rekey({ date: THU, session: 'upperA' }, { status: 'complete' }, taken), null, 'editing an old session keeps it');
  assert.equal(P.rekey({ date: THU, session: 'upperA', uid: 'b' }, { status: 'in_progress', uid: 'a' }, taken), null);
  taken.add('2026-11-05-upperA~2');
  assert.equal(P.rekey({ date: THU, session: 'upperA', uid: 'c' }, { status: 'complete', uid: 'a' }, taken), 'upperA~3');
  assert.equal(P.baseKey('upperA~3'), 'upperA'); assert.equal(P.baseKey('run3'), 'run');
});

test('W1 the Watch gets moved, reduced and switched workouts, for this week and next (offline cache)', () => {
  const prog = def(), ub = `${MON}:upperB:1`, lb = `${MON}:lowerB:1`;
  const changes = [{ id: ub, change: { week: MON, date: SAT, source: 'manual' } }, { id: lb, change: { week: MON, reduced: true, source: 'readiness' } }];
  const out = P.serve({ prog, changes, sessions: [lift('upperA', MON)], settings: {}, today: WED });
  const o = id => out.occs.find(x => x.occ === id);
  assert.equal(o(ub).date, SAT);
  assert.equal(o(lb).reduced, true); assert.ok(o(lb).ex.length < out.workouts.lowerB.exercises.length);
  assert.equal(o(`${MON}:upperA:1`).status, 'done');
  assert.equal(out.occs.filter(x => x.date >= NEXT).length, 6, 'next week is cached too');
  assert.ok(out.workouts.upperA.exercises[0].alts.length > 0);
  for (const k of ['upperA', 'lowerA', 'upperB', 'lowerB']) assert.ok(out.workouts[k], 'old Watch builds keep their four workouts');
  const sw = thursdaySwitch();
  const out2 = P.serve({ prog: sw.prog, changes: sw.rows, sessions: [lift('upperA', MON), lift('lowerA', WED)], settings: {}, today: THU });
  const fri = out2.occs.find(x => x.date === FRI && x.type === 'lift');
  assert.equal(fri.key, 'fbC'); assert.deepEqual(fri.ex.map(e => e.id), ['inc-db', 'cable-row', 'rear']);
  assert.ok(out2.workouts.fbA && out2.workouts.fbC);
});

test('Z1 deterministic: the same input always gives the same output', () => {
  const a = JSON.stringify(thursdaySwitch()), b = JSON.stringify(thursdaySwitch());
  assert.equal(a, b);
});

test('L4 nothing saved yet: the original plan with its original set counts, even after a break from legs', () => {
  const hist = [lift('lowerA', '2026-09-01')];
  for (let d = '2026-09-03'; d < '2026-11-09'; d = P.addDays(d, 7)) hist.push(lift('upperA', d));
  const v = P.volumeFor(null, { sessions: hist, changes: [] }, NEXT);
  assert.equal(v.stage, 'reg'); assert.deepEqual(v.fresh, {});
  const s = P.weekSchedule({ prog: null, changes: [], sessions: hist, today: '2026-11-08', weekStart: NEXT });
  assert.deepEqual(s.workouts.lowerA.ex.map(e => e.sets), [4, 3, 3, 3, 4]);
});
