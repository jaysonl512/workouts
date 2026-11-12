// Tests for progression.js. Run: node --test tests/
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const P = require('../progression.js');
const { EXMAP, PLAN, ALTS, altId } = require('../plan.js');

const cfg = (id, settings) => P.configFor(EXMAP[id], settings);
const custom = (ex, settings) => P.configFor({ alt: false, ...ex }, settings);
const pairs = sets => sets.map(s => [s.w, s.r]);
const addDays = (d, n) => new Date(Date.parse(d + 'T12:00:00Z') + n * 864e5).toISOString().slice(0, 10);

/* A logged session from a plan: reps per planned set (fewer = sets not logged), optional actual weights and edits. */
function logged(plan, date, reps, o = {}) {
  const sets = reps.map((r, i) => {
    const p = plan.sets[i], w = o.w && o.w[i] != null ? o.w[i] : p.w;
    const s = { w, r, pw: p.w, pr: p.r, tw: o.tw ? o.tw[i] : p.w, tr: o.tr ? o.tr[i] : p.r };
    return s;
  });
  return { date, sets: (o.warmups || []).concat(sets), prog: plan.state, diff: o.diff };
}
/* Runs weeks: each step is [reps, opts]. Returns the plans seen, oldest first. */
function weeks(c, hist, start, steps) {
  const plans = []; let date = start;
  for (const [reps, o] of steps) {
    const plan = P.planFor(c, hist, date); plans.push(plan);
    hist = [logged(plan, date, reps, o || {}), ...hist];
    date = addDays(date, 7);
  }
  plans.push(P.planFor(c, hist, date));
  return plans;
}
const legacy = (date, sets) => ({ date, sets: sets.map(([w, r]) => ({ w, r })) });

/* ---------- pyramid ---------- */
const incline = cfg('inc-db');
const nov5 = legacy('2026-11-05', [[35, 12], [40, 12], [45, 11], [50, 10]]);

test('P1 pyramid starts from the Nov 5 incline session', () => {
  const p = P.planFor(incline, [nov5], '2026-11-12');
  assert.deepEqual(pairs(p.sets), [[40, 12], [45, 10], [50, 8], [55, 6]]);
  assert.deepEqual(pairs(p.warmups), [[25, 8], [35, 4]]);
});

test('P2-P3 pyramid four weeks: top set +1 rep per success, shift at the top of the band, hold after a miss', () => {
  const plans = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 7]], [[12, 10, 8, 8]], [[12, 10, 9, 8]], [[12, 9, 7, 5]]]);
  assert.deepEqual(pairs(plans[0].sets), [[40, 12], [45, 10], [50, 8], [55, 6]]);
  assert.deepEqual(pairs(plans[1].sets), [[40, 12], [45, 10], [50, 8], [55, 7]]);
  assert.deepEqual(pairs(plans[2].sets), [[40, 12], [45, 10], [50, 8], [55, 8]]);
  assert.deepEqual(pairs(plans[3].sets), [[45, 12], [50, 10], [55, 8], [60, 6]]);
  assert.equal(plans[4].last, 'missed');
  assert.deepEqual(pairs(plans[4].sets), [[45, 12], [50, 10], [55, 8], [60, 6]]);
  assert.equal(plans[4].state.miss, 1);
});

test('P4 borderline after a miss holds and resets the streak', () => {
  const plans = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 7]], [[12, 10, 8, 8]], [[12, 10, 9, 8]], [[12, 9, 7, 5]], [[12, 10, 7, 5]]]);
  assert.equal(plans[5].last, 'borderline');
  assert.equal(plans[5].state.miss, 0);
  assert.deepEqual(pairs(plans[5].sets), [[45, 12], [50, 10], [55, 8], [60, 6]]);
});

test('P5 a second miss in a row steps the pyramid down', () => {
  const plans = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 7]], [[12, 10, 8, 8]], [[12, 10, 9, 8]], [[12, 9, 7, 5]], [[12, 9, 6, 5]]]);
  assert.equal(plans[5].last, 'missed');
  assert.deepEqual(pairs(plans[5].sets), [[40, 12], [45, 10], [50, 8], [55, 6]]);
  assert.equal(plans[5].state.miss, 0);
});

test('P6 Hard at the top of the band blocks the shift', () => {
  const plans = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 7]], [[12, 10, 8, 8]], [[12, 10, 9, 8], { diff: 'hard' }]]);
  assert.deepEqual(pairs(plans[3].sets), [[40, 12], [45, 10], [50, 8], [55, 8]]);
});

test('P7 beating the top-set target by 2 still adds only 1 rep', () => {
  const plans = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 8]]]);
  assert.deepEqual(pairs(plans[1].sets), [[40, 12], [45, 10], [50, 8], [55, 7]]);
});

/* ---------- straight sets ---------- */
const bench = custom({ id: 'bench-s', name: 'Bench press', sets: 4, reps: [6, 8], eq: 'barbell' });
const benchStart = legacy('2026-11-05', [[155, 7], [155, 7], [155, 7], [155, 6]]);

test('S1 straight sets four weeks', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 7, 7]], [[8, 8, 8, 8]], [[7, 6, 6, 5]]]);
  assert.deepEqual(pairs(plans[0].sets), Array(4).fill([155, 7]));
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 8]));
  assert.deepEqual(pairs(plans[2].sets), Array(4).fill([160, 6]));
  assert.equal(plans[3].last, 'borderline');
  assert.deepEqual(pairs(plans[3].sets), Array(4).fill([160, 6]));
});

test('S2 one set at the top of the range does not raise the weight', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[8, 7, 7, 7]]]);
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 8]));
});

test('S3 every set at the top of the range raises the weight even from a lower target', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 8, 8]]]);
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([160, 6]));
});

test('S4 two misses in a row step down; S5 a borderline in between breaks the streak', () => {
  const start = legacy('2026-11-05', [[160, 5], [160, 5], [160, 5], [160, 5]]);   // calibrates to 160 x 6
  let plans = weeks(bench, [start], '2026-11-12', [[[5, 5, 4, 4]], [[5, 5, 4, 4]]]);
  assert.deepEqual(pairs(plans[0].sets), Array(4).fill([160, 6]));
  assert.deepEqual(pairs(plans[2].sets), Array(4).fill([155, 6]));
  plans = weeks(bench, [start], '2026-11-12', [[[5, 5, 4, 4]], [[6, 6, 6, 5]], [[5, 5, 4, 4]]]);
  assert.deepEqual(pairs(plans[3].sets), Array(4).fill([160, 6]));
  assert.equal(plans[3].state.miss, 1);
});

test('S6 an older ramped session starts straight sets conservatively, not at the heaviest set for every set', () => {
  const row = cfg('row');   // 4 x 6-10, machine
  const p = P.planFor(row, [legacy('2026-11-02', [[95, 10], [115, 10], [135, 8], [140, 7]])], '2026-11-09');
  assert.deepEqual(pairs(p.sets), Array(4).fill([135, 6]));
  const curl = cfg('ss-curl');
  assert.deepEqual(pairs(P.planFor(curl, [legacy('2026-11-05', [[40, 12], [40, 12], [40, 12]])], '2026-11-12').sets), Array(3).fill([45, 10]));
});

/* ---------- top set + back-offs ---------- */
const dead = cfg('deadlift');
const deadStart = legacy('2026-11-06', [[225, 4], [190, 6], [190, 6]]);

test('T1 top set and back-offs four weeks', () => {
  const plans = weeks(dead, [deadStart], '2026-11-13', [[[5, 7, 7]], [[6, 8, 7]], [[5, 6, 5]]]);
  assert.deepEqual(pairs(plans[0].sets), [[225, 5], [190, 7], [190, 7]]);
  assert.deepEqual(pairs(plans[1].sets), [[225, 6], [190, 8], [190, 8]]);
  assert.deepEqual(pairs(plans[2].sets), [[230, 4], [195, 6], [195, 6]]);
  assert.deepEqual(pairs(plans[3].sets), [[230, 5], [195, 6], [195, 6]]);
});

test('T1b top set Met while back-offs Borderline: top progresses, back-offs hold, no overall verdict', () => {
  const plans = weeks(dead, [deadStart], '2026-11-13', [[[5, 7, 7]], [[6, 8, 7]], [[5, 6, 5]]]);
  assert.deepEqual(plans[3].last, { top: 'met', back: 'borderline' });
  assert.equal(plans[3].sets[0].r, 5);       // top set +1
  assert.equal(plans[3].sets[1].r, 6);       // back-offs hold
  assert.equal(plans[3].state.missB, 0);
});

test('T2 back-offs are never as heavy as the top set', () => {
  const c = custom({ id: 'x', name: 'Deadlift', sets: 3, reps: [4, 6], eq: 'barbell', prog: { s: 'topback', top: [4, 6], back: [6, 8], backSets: 2, pct: 1 } });
  const p = P.planFor(c, [legacy('2026-11-06', [[200, 5]])], '2026-11-13');
  assert.deepEqual(pairs(p.sets), [[200, 6], [195, 6], [195, 6]]);
});

test('T3 top set missed twice: one step down and back-off reps reset', () => {
  const plans = weeks(dead, [deadStart], '2026-11-13', [[[3, 7, 7]], [[3, 8, 8]]]);
  assert.deepEqual(pairs(plans[2].sets), [[220, 4], [185, 6], [185, 6]]);
});

test('T4 back-offs missed twice at the bottom of their band keep their weight', () => {
  const start = legacy('2026-11-06', [[225, 4], [190, 5], [190, 5]]);   // back-offs calibrate to 6
  const plans = weeks(dead, [start], '2026-11-13', [[[4, 4, 4]], [[4, 4, 4]]]);   // top set Borderline both times
  assert.equal(plans[0].sets[1].r, 6);
  assert.deepEqual(plans[2].last, { top: 'borderline', back: 'missed' });
  assert.deepEqual(pairs(plans[2].sets).slice(1), [[190, 6], [190, 6]]);
});

/* ---------- assisted moves (less assistance is harder) ---------- */
const pull = cfg('pullup');
const pullStart = legacy('2026-11-05', [[40, 7], [40, 7], [40, 7]]);      // 40 lb assist x 8

test('A1 more assistance than planned is a shortfall, not a gain', () => {
  const plans = weeks(pull, [pullStart], '2026-11-12', [[[8, 8, 8], { w: [45, 45, 45] }]]);
  assert.equal(plans[1].last, 'missed');
  assert.deepEqual(pairs(plans[1].sets), Array(3).fill([40, 8]));
});

test('A2 less assistance on every set with full reps: the plan adopts it', () => {
  const plans = weeks(pull, [pullStart], '2026-11-12', [[[8, 8, 8], { w: [35, 35, 35] }]]);
  assert.equal(plans[1].last, 'met');
  assert.deepEqual(pairs(plans[1].sets), Array(3).fill([35, 8]));
});

test('A3 top of the range takes assistance off; A4 two misses add it back', () => {
  let plans = weeks(pull, [pullStart], '2026-11-12', [[[12, 12, 12]]]);
  assert.deepEqual(pairs(plans[1].sets), Array(3).fill([35, 6]));
  plans = weeks(pull, [pullStart], '2026-11-12', [[[5, 5, 5]], [[5, 5, 5]]]);
  assert.deepEqual(pairs(plans[2].sets), Array(3).fill([45, 6]));
});

test('A5 older pull-up history with ramped assistance starts from the middle assistance', () => {
  const p = P.planFor(pull, [legacy('2026-11-05', [[60, 12], [50, 9], [40, 7]])], '2026-11-12');
  assert.deepEqual(pairs(p.sets), Array(3).fill([50, 10]));
  assert.equal(p.unit, 'lb assist');
});

test('A6 assisted directions and A7 time off adds assistance', () => {
  assert.equal(P.harder(pull, 40), 35);
  assert.equal(P.easier(pull, 40), 45);
  assert.equal(P.asHard(pull, 35, 40), true);
  assert.equal(P.asHard(pull, 45, 40), false);
  const p = P.planFor(pull, [pullStart], '2027-02-20');
  assert.equal(p.sets[0].w, 45);
});

/* ---------- incomplete ---------- */
test('I1 fewer sets than planned is Incomplete: hold, streak unchanged', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 8]]]);
  assert.equal(plans[1].last, 'incomplete');
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 7]));
});

test('I2 Incomplete even when a logged set fell short, and it does not break a missed streak', () => {
  const start = legacy('2026-11-05', [[160, 5], [160, 5], [160, 5], [160, 5]]);
  const plans = weeks(bench, [start], '2026-11-12', [[[5, 5, 4, 4]], [[6, 3]], [[5, 5, 4, 4]]]);
  assert.equal(plans[2].last, 'incomplete');
  assert.equal(plans[2].state.miss, 1);
  assert.deepEqual(pairs(plans[3].sets), Array(4).fill([155, 6]));
});

/* ---------- ratings ---------- */
test('R1 Easy on a Met session changes nothing; R2 Easy never rescues a miss', () => {
  const a = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 7, 7], { diff: 'easy' }]]);
  const b = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 7, 7]]]);
  assert.deepEqual(a[1].sets, b[1].sets);
  const m = weeks(bench, [benchStart], '2026-11-12', [[[6, 6, 5, 5], { diff: 'easy' }]]);
  assert.equal(m[1].last, 'missed');
  assert.deepEqual(pairs(m[1].sets), Array(4).fill([155, 7]));
});

test('R3 Hard with every set at the top keeps the weight', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 8, 8], { diff: 'hard' }]]);
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 8]));
});

/* ---------- manual changes ---------- */
test('O1 heavier on every set with full reps: plan adopts the weight, same reps', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[7, 7, 7, 7], { w: [165, 165, 165, 165] }]]);
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([165, 7]));
});

test('O2 lighter than planned counts as a shortfall and keeps the planned weight', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[8, 8, 8, 8], { w: [145, 145, 145, 145] }]]);
  assert.equal(plans[1].last, 'missed');
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 7]));
});

test('O3 editing a target down does not earn progression (judged on the original target)', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[7, 7, 7, 7], { w: [145, 145, 145, 145], tw: [145, 145, 145, 145] }]]);
  assert.equal(plans[1].last, 'missed');
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 7]));
});

test('O4 one heavier set does not move the plan', () => {
  const plans = weeks(bench, [benchStart], '2026-11-12', [[[7, 7, 7, 7], { w: [165, 155, 155, 155] }]]);
  assert.equal(plans[1].last, 'met');
  assert.deepEqual(pairs(plans[1].sets), Array(4).fill([155, 8]));
});

test('O5 original target, edited target and actual are all kept on the set', () => {
  const plan = P.planFor(bench, [benchStart], '2026-11-12');
  const e = logged(plan, '2026-11-12', [7], { w: [150], tw: [150], tr: [7] });
  assert.deepEqual(P.cleanSet(e.sets[0]), { w: 150, r: 7, pw: 155, pr: 7, tw: 150, tr: 7 });
});

/* ---------- history, time off, equipment ---------- */
test('H1 no history: reps only, no weight, no warm-ups', () => {
  const p = P.planFor(incline, [], '2026-11-12');
  assert.deepEqual(pairs(p.sets), [[null, 12], [null, 10], [null, 8], [null, 6]]);
  assert.deepEqual(p.warmups, []);
});

test('H2 an alternative keeps its own history', () => {
  const sessions = [{ id: 'a', date: '2026-11-03', entries: [{ id: altId('bench', 'Dumbbell bench press'), slot: 'bench', sets: [{ w: 60, r: 10 }] }] }];
  assert.equal(P.historyFor(sessions, 'bench').length, 0);
  assert.equal(P.historyFor(sessions, altId('bench', 'Dumbbell bench press')).length, 1);
});

test('H3 changing equipment starts the history fresh', () => {
  const plan = P.planFor(bench, [benchStart], '2026-11-12');
  const entry = logged(plan, '2026-11-12', [7, 7, 7, 7]);
  const machine = custom({ id: 'bench-s', name: 'Bench press', sets: 4, reps: [6, 8], eq: 'machine' });
  assert.equal(P.planFor(machine, [entry, benchStart], '2026-11-19').sets[0].w, null);
});

test('G1-G3 time off', () => {
  const plan = P.planFor(bench, [benchStart], '2026-11-12');
  const met = logged(plan, '2026-11-12', [8, 8, 8, 8]);
  assert.deepEqual(pairs(P.planFor(bench, [met], '2026-12-12').sets), Array(4).fill([155, 7]));   // 30 days: same plan
  assert.deepEqual(pairs(P.planFor(bench, [met], '2027-01-01').sets), Array(4).fill([150, 6]));   // 50 days: one step
  const heavy = legacy('2026-11-05', [[160, 7], [160, 7], [160, 7], [160, 7]]);
  assert.equal(P.planFor(bench, [heavy], '2027-02-13').sets[0].w, 140);                         // 100 days: 90% of 160
});

test('E1-E5 equipment increments', () => {
  assert.equal(P.up(incline, 22.5), 25);
  assert.equal(P.up(incline, 25), 30);
  assert.equal(P.down(incline, 30), 25);
  assert.equal(P.down(incline, 25), 22.5);
  const machine10 = cfg('leg-ext', { step: 10 });
  assert.equal(P.up(machine10, 100), 110);
  assert.equal(P.snapDown(dead, 191.25), 190);
  assert.equal(cfg('fly').step, 2.5);
  assert.equal(P.configFor(EXMAP.bench).eq, 'dumbbell');   // bench is dumbbell bench press (2026-11-12)
  assert.equal(P.configFor(EXMAP[altId('bench', 'Barbell bench press')]).eq, 'barbell');
});

/* ---------- warm-ups and volume ---------- */
test('W1 warm-ups come from the heaviest planned set and stay below the first working set', () => {
  const plans = weeks(dead, [deadStart], '2026-11-13', []);
  assert.deepEqual(pairs(plans[0].warmups), [[110, 8], [155, 4]]);
});

test('W2 warm-up sets are ignored for progression and volume; W3 unmarked sets count', () => {
  const plan = P.planFor(bench, [benchStart], '2026-11-12');
  const withWu = logged(plan, '2026-11-12', [8, 8, 7, 7], { warmups: [{ w: 95, r: 8, wu: true }, { w: 135, r: 4, wu: true }] });
  const without = logged(plan, '2026-11-12', [8, 8, 7, 7]);
  assert.deepEqual(P.planFor(bench, [withWu], '2026-11-19').sets, P.planFor(bench, [without], '2026-11-19').sets);
  assert.equal(P.setVolume(bench, { w: 95, r: 8, wu: true }), 0);
  assert.equal(P.setVolume(bench, { w: 95, r: 8 }), 760);
});

test('V1 dumbbell volume counts both dumbbells for old and new sessions alike', () => {
  const vol = sets => sets.reduce((a, x) => a + P.setVolume(incline, x), 0);
  assert.equal(vol(nov5.sets), 2 * (35 * 12 + 40 * 12 + 45 * 11 + 50 * 10));
  const later = [{ w: 40, r: 12 }, { w: 45, r: 10 }, { w: 50, r: 8 }, { w: 55, r: 6 }];
  const oldRatio = (40 * 12 + 45 * 10 + 50 * 8 + 55 * 6) / (35 * 12 + 40 * 12 + 45 * 11 + 50 * 10);
  assert.equal(vol(later) / vol(nov5.sets), oldRatio);
  assert.equal(P.setVolume(pull, { w: 40, r: 8 }, 180), 1120);
  assert.equal(P.setVolume(pull, { w: 40, r: 8 }), 0);
});

/* ---------- sync and determinism ---------- */
test('Y1 web row conversion keeps targets, warm-ups, ratings, state and plans', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
  const i = html.indexOf('const rowToSess'), j = html.indexOf('async function sbLoad');
  const ctx = {}; vm.runInNewContext(html.slice(i, j) + '\nglobalThis.out={rowToSess,sessToRow};', ctx);
  const plan = P.planFor(bench, [benchStart], '2026-11-12');
  const sess = { id: '2026-11-12-upperA', date: '2026-11-12', session: 'upperA', name: 'Upper A', type: 'lift', source: 'web', savedAt: '2026-11-12T17:00:00.000Z', updatedAt: '2026-11-12T17:00:00.000Z',
    entries: [{ id: 'bench', name: 'Bench press', diff: 'moderate', prog: plan.state, sets: [{ w: 95, r: 8, wu: true }, { w: 150, r: 7, pw: 155, pr: 7, tw: 150, tr: 7 }] }], plans: { bench: plan } };
  const row = JSON.parse(JSON.stringify(ctx.out.sessToRow(sess, 'u1')));
  const back = ctx.out.rowToSess(row);
  assert.deepEqual(JSON.parse(JSON.stringify(back.entries)), JSON.parse(JSON.stringify(sess.entries)));
  assert.deepEqual(JSON.parse(JSON.stringify(back.plans)), JSON.parse(JSON.stringify(sess.plans)));
});

test('Y3 an old entry without the new fields still plans; Y4 a plan survives JSON (handoff, Watch cache)', () => {
  const plan = P.planFor(incline, [nov5], '2026-11-12');
  const copy = JSON.parse(JSON.stringify(plan));
  const a = P.planFor(incline, [logged(plan, '2026-11-12', [12, 10, 8, 7])], '2026-11-19');
  const b = P.planFor(incline, [logged(copy, '2026-11-12', [12, 10, 8, 7])], '2026-11-19');
  assert.deepEqual(a, b);
});

test('Y5 buildPlans covers every lift exercise and alternative', () => {
  const out = P.buildPlans({ sessions: [{ id: 'x', date: '2026-11-05', data: { entries: [{ id: 'inc-db', sets: nov5.sets }] } }], settings: {}, today: '2026-11-12', plan: { PLAN, ALTS, altId, EXMAP } });
  assert.deepEqual(Object.keys(out.sessions).sort(), ['lowerA', 'lowerB', 'upperA', 'upperB']);
  assert.deepEqual(pairs(out.sessions.upperB['inc-db'].sets), [[40, 12], [45, 10], [50, 8], [55, 6]]);
  assert.ok(out.sessions.upperA[altId('bench', 'Barbell bench press')]);
});

test('D1 same inputs, same output, and no clock is read', () => {
  const realNow = Date.now, RealDate = Date;
  globalThis.Date = class extends RealDate { constructor(...a) { if (!a.length) throw new Error('clock read'); super(...a) } static now() { throw new Error('clock read') } };
  try {
    const a = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 7]], [[12, 9, 7, 5]]]);
    const b = weeks(incline, [nov5], '2026-11-12', [[[12, 10, 8, 7]], [[12, 9, 7, 5]]]);
    assert.deepEqual(a, b);
  } finally { globalThis.Date = RealDate; Date.now = realNow }
});
