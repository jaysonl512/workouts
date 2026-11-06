/* Session's training programs: which workouts you do, on which days, and how many sets of each.
   Deterministic rules, no AI and no clock: "today" is always passed in, so the same settings, history and date
   always give the same schedule.

   Kept separate from progression.js. This file decides exercises, set counts, frequency and days; progression.js
   still decides every weight and rep target. The only thing passed between them is an exercise definition
   (id, sets, reps, structure), exactly like plan.js passes today. History is per exercise id, so changing
   programs, days or set counts never resets progression.

   Used by the web app (index.html), the Supabase Edge Function "plans" (which serves the Watch its schedule and
   workouts, cached for offline use) and tests/programs.test.js.

   Words used below
   - Working sets: logged sets without wu:true. "Sets" always means this actual count.
   - Muscle credit: working sets weighted by muscle (plan.js MUSCLES): 1 per set for a main muscle, 0.5 for a
     supporting one. Sets and credits are separate numbers and never mixed.
   - Groups: legs = quads + glutes + hamstrings, push = chest + shoulders + triceps, pull = back + biceps.
   - Demanding: a session with at least 12 credits for a group (9 at the Returning level).
   - Occurrence: one scheduled workout in one week, with a stable id that survives moves:
     "<week start>:<key>:<n>" for the program's own, ":t:" for ones made by a program switch, ":m:" for ones you
     added. A workout saved from an occurrence stores its id (data.occ), so it is matched exactly.
   - Week: 7 days from the program's week start (Monday unless changed). */
(function(){
'use strict';
const WP = globalThis.WorkoutPlan || (typeof require!=='undefined' ? require('./plan.js') : null);
const { PLAN, ALTS, altId, EXMAP, MUSCLES } = WP;

/* ---------- constants ---------- */
const MUSCLE_LIST = ['chest','back','shoulders','triceps','biceps','quads','glutes','hamstrings','calves','core'];
const MAJOR = ['chest','back','shoulders','quads','glutes','hamstrings'];
const GROUPS = {legs:['quads','glutes','hamstrings'], push:['chest','shoulders','triceps'], pull:['back','biceps']};
const GROUP_OF = {quads:'legs',glutes:'legs',hamstrings:'legs',calves:'legs',chest:'push',shoulders:'push',triceps:'push',back:'pull',biceps:'pull'};
const SPACE = {legs:3, push:2, pull:2};               // days between two demanding sessions for the same group
const DEMANDING = {returning:9, regular:12, higher:12};
const LEG_CAP = {returning:24, regular:40, higher:48};   // weekly leg credits (quads + glutes + hamstrings)
const LEVELS = {returning:'Returning', regular:'Regular', higher:'Higher volume'};
const RUN_KINDS = {easy:'Easy run', long:'Long run', intervals:'Intervals'};
const DAY = 86400000;
const r1 = x => Math.round(x*10)/10;

/* ---------- dates (YYYY-MM-DD, computed in UTC so time zones never shift a day) ---------- */
const toD = ds => new Date(ds+'T12:00:00Z');
const addDays = (ds,n) => new Date(toD(ds).getTime()+n*DAY).toISOString().slice(0,10);
const dow = ds => toD(ds).getUTCDay();
const daysBetween = (a,b) => Math.round((toD(b)-toD(a))/DAY);
const weekStartOf = (ds, start) => addDays(ds, -((dow(ds)-(start==null?1:start)+7)%7));
const DOW_NAME = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];

/* ---------- workouts ---------- */
/* Each workout: [exercise id, sets, optional?]. Optional (*) accessories are the first left out at the Returning
   level or in a reduced workout. Pyramid and top-set lifts take their set count from their structure. */
const OPT = {upperA:'db-curl', lowerA:'lunge', upperB:'rear', lowerB:'front-sq'};
const W = {};
['upperA','lowerA','upperB','lowerB'].forEach(k=>{ const S=PLAN.sessions[k]; W[k]={name:S.name, ex:S.ex.map(e=>[e.id, e.sets, OPT[k]===e.id?1:0])} });
Object.assign(W, {
  fbA:{name:'Full Body A', ex:[['squat',4],['bench',4],['row',3],['leg-curl',2],['db-curl',2,1],['plank',2]]},
  fbB:{name:'Full Body B', ex:[['deadlift',3],['ohp-db',3],['pulldown',3],['lunge',2,1],['pushdown',2],['knee-raise',2]]},
  fbC:{name:'Full Body C', ex:[['inc-db',4],['cable-row',3],['hip-thrust',3],['leg-ext',2,1],['rear',2],['calf-st',3]]},
  srA:{name:'Strength A', ex:[['squat',4],['bench',4],['row',3],['db-curl',2,1],['plank',2]]},
  srB:{name:'Strength B', ex:[['deadlift',3],['ohp-db',3],['pulldown',3],['pushdown',2,1],['knee-raise',2]]},
  srC:{name:'Strength C', ex:[['inc-db',4],['cable-row',3],['hip-thrust',2],['rear',2,1],['calf-st',2]]},
  pushA:{name:'Push A', ex:[['bench',4],['ohp-db',3],['fly',3],['lat-raise',3,1],['pushdown',3]]},
  pullA:{name:'Pull A', ex:[['row',4],['pullup',3],['cable-row',3],['rear',3,1],['db-curl',3]]},
  legsA:{name:'Legs A', ex:[['squat',4],['rdl',3],['lunge',2,1],['leg-curl',3],['calf-st',3],['knee-raise',2]]},
  upper:{name:'Upper', ex:[['inc-db',4],['pulldown',3],['lat-raise',2],['ss-curl',2,1],['ss-tri',2]]},
  legsB:{name:'Legs B', ex:[['deadlift',3],['front-sq',2,1],['hip-thrust',3],['leg-ext',2],['calf-seat',3],['plank',2]]},
  pushB:{name:'Push B', ex:[['inc-db',4],['ohp',3],['lat-raise',2,1],['ss-tri',2]]},
  pullB:{name:'Pull B', ex:[['cable-row',3],['pulldown',3],['rear',2,1],['ss-curl',2]]},
});

/* Programs. freq: lifts per week -> workouts in order, default days (0 = Sunday), runs, and frequency adjustments
   (so more days spreads volume instead of copying a full session). fixedOrder keeps the workouts on their days. */
const runsOf = list => list.map(([dow,kind,optional])=>({dow,kind,optional:!!optional}));
const TEMPLATES = {
  current:{name:'Current plan', blurb:'Upper A, Lower A, Upper B and Lower B on your usual days', fixedOrder:true,
    freq:{4:{w:['upperA','lowerA','upperB','lowerB'], days:[1,3,4,5], runs:runsOf([[2,'easy'],[6,'long',1]])}}},
  upperLower:{name:'Upper / Lower', blurb:'Two upper and two lower days, legs 3 days apart',
    freq:{4:{w:['upperA','lowerA','upperB','lowerB'], days:[1,2,4,5], runs:runsOf([[3,'easy'],[6,'long',1]])}}},
  balanced:{name:'Balanced Fitness', blurb:'Three full-body days. Good for getting back into a routine',
    freq:{3:{w:['fbA','fbB','fbC'], days:[1,3,5], runs:runsOf([[2,'easy',1],[6,'long',1]])}}},
  ppl:{name:'Push / Pull / Legs', blurb:'3 to 6 days. More days spreads the volume, it does not copy it',
    freq:{
      3:{w:['pushA','pullA','legsA'], days:[1,3,5], runs:runsOf([[2,'easy',1],[6,'long',1]])},
      4:{w:['pushA','pullA','legsA','upper'], days:[1,2,4,5], runs:runsOf([[3,'easy',1]]),
        adjust:{pushA:{sets:{fly:2,pushdown:2}}, pullA:{sets:{'cable-row':2,'db-curl':2}}}},
      5:{w:['pushA','pullA','legsA','upper','legsB'], days:[1,2,3,5,6], runs:runsOf([[4,'easy',1]]),
        adjust:{pushA:{sets:{fly:2,pushdown:2}}, pullA:{sets:{'cable-row':2,'db-curl':2}}, legsA:{remove:['rdl','calf-st']}}},
      6:{w:['pushA','pullA','legsA','pushB','pullB','legsB'], days:[1,2,3,4,5,6], runs:[],
        adjust:{pushA:{remove:['lat-raise'],sets:{fly:2,pushdown:2}}, pullA:{remove:['cable-row','rear']}, legsA:{remove:['rdl','calf-st']}}}}},
  strengthRun:{name:'Strength + Running', blurb:'2 or 3 lifts with lighter leg work, plus 2 or 3 runs',
    freq:{
      2:{w:['srA','srB'], days:[1,4], runs:runsOf([[2,'easy'],[6,'long'],[3,'easy',1]]),
        adjust:{srA:{sets:{row:4}, add:[['fly',3,0,'row']]}, srB:{sets:{'ohp-db':4,pulldown:4}, add:[['calf-st',3,0,'pushdown']]}}},
      3:{w:['srA','srB','srC'], days:[1,3,5], runs:runsOf([[2,'easy'],[6,'long'],[4,'intervals',1]])}}},
};

function defaultConfig(){
  return {v:1, template:'current', lifts:4, days:[1,3,4,5], runs:runsOf([[2,'easy'],[6,'long',1]]), rotation:0,
    level:'regular', levelSince:null, rampHold:null, weekStart:1, readiness:true, edits:{}, prefs:{use:{},avoid:[]}, startedOn:null};
}
function normalize(c){
  const d=defaultConfig(), o={...d, ...(c||{})};
  if(!TEMPLATES[o.template]) o.template='current';
  const t=TEMPLATES[o.template];
  if(!t.freq[o.lifts]) o.lifts=+Object.keys(t.freq)[0];
  const f=t.freq[o.lifts];
  if(!Array.isArray(o.days) || o.days.length!==f.w.length) o.days=f.days.slice();
  if(!Array.isArray(o.runs)) o.runs=f.runs.map(x=>({...x}));
  o.prefs={use:{...((o.prefs||{}).use||{})}, avoid:[...((o.prefs||{}).avoid||[])]};
  o.edits=o.edits||{};
  if(!LEVELS[o.level]) o.level='regular';
  return o;
}
/* A new program's settings, keeping your preferences, level and week start. */
function configFor(template, lifts, base){
  const b=normalize(base), t=TEMPLATES[template], n=t.freq[lifts]?lifts:+Object.keys(t.freq)[0], f=t.freq[n];
  return normalize({...b, template, lifts:n, days:f.days.slice(), runs:f.runs.map(x=>({...x})), rotation:0, edits:{}, startedOn:null});
}
/* The settings in force on a date. prog = {config, past:[{config, until}]} (past = earlier programs). */
function configOn(prog, date){
  const past=((prog&&prog.past)||[]).filter(p=>p&&p.until).sort((a,b)=>a.until<b.until?-1:1);
  for(const p of past) if(date<=p.until) return normalize(p.config);
  return prog && prog.config ? normalize(prog.config) : {...defaultConfig(), implicit:true};
}

/* ---------- sessions and volume ---------- */
const baseKey = k => /^run\d*$/.test(k||'') ? 'run' : String(k||'').replace(/~\d+$/,'');
/* Web session objects or Supabase rows {id,date,session,type,data} to one shape. */
function sessList(list){
  return (list||[]).map(s=>s && s.data && !s.entries ? {...s.data, id:s.id, date:s.date, session:s.session||s.data.session, type:s.type||s.data.type} : s)
    .filter(s=>s && s.date).map(s=>({...s, type: s.type || (s.run?'run':s.yoga?'yoga':s.other?'other':s.entries?'lift':'other')}));
}
const slotOf = id => (EXMAP[id]&&EXMAP[id].slot) || String(id||'').split('~')[0];
const musclesOf = id => MUSCLES[slotOf(id)] || {};
const primaries = id => Object.entries(musclesOf(id)).filter(([,w])=>w>=1).map(([m])=>m);
const emptyCredits = () => Object.fromEntries(MUSCLE_LIST.map(m=>[m,0]));
/* Actual working sets and muscle credits of logged sessions (warm-ups and empty sets never count). */
function volumeOf(sessions){
  const credits=emptyCredits(); let sets=0;
  sessList(sessions).forEach(s=>(s.entries||[]).forEach(e=>{
    const n=(e.sets||[]).filter(x=>x && !x.wu && (+x.r||0)>0).length; if(!n) return;
    sets+=n; Object.entries(musclesOf(e.id)).forEach(([m,w])=>{ credits[m]+=n*w });
  }));
  MUSCLE_LIST.forEach(m=>credits[m]=r1(credits[m]));
  return {sets, credits};
}
/* Planned sets and credits of a workout (or the exercises an occurrence keeps). */
function plannedVolume(workout, only){
  const credits=emptyCredits(); let sets=0;
  exList(workout, only).forEach(e=>{ sets+=e.sets; Object.entries(musclesOf(e.id)).forEach(([m,w])=>{ credits[m]+=e.sets*w }) });
  MUSCLE_LIST.forEach(m=>credits[m]=r1(credits[m]));
  return {sets, credits};
}
const groupLoads = cr => Object.fromEntries(Object.entries(GROUPS).map(([g,ms])=>[g, r1(ms.reduce((s,m)=>s+(cr[m]||0),0))]));
/* A workout's exercises, optionally narrowed to an occurrence's own list [{id, sets}]. */
function exList(workout, only){
  const ex=(workout&&workout.ex)||[];
  if(!only) return ex;
  return only.map(o=>{ const e=ex.find(x=>x.id===o.id); return e ? {...e, sets:o.sets!=null?o.sets:e.sets} : null }).filter(Boolean);
}

/* ---------- training level ---------- */
function weekLiftCount(prog, ws){ const c=configOn(prog, ws); return TEMPLATES[c.template].freq[c.lifts].w.length }
const checkinsOf = changes => (changes||[]).filter(c=>c && String(c.id).startsWith('chk:')).map(c=>({date:c.id.slice(4), ...(c.change||{})}));
/* A week counts toward building volume back up only if recovery was good and enough was done: at least 2/3 of the
   scheduled lifts done (skips do not lower that bar), no "Very sore", no recovery day, no reduced workout, at most
   one "A little sore", and weekly leg credits within the cap. A skip is not a recovery problem: it only matters
   through the lifts it leaves undone. The same rules apply wherever a choice was made. A week without lifting
   changes nothing. */
function weekQualifies(prog, o, w, level){
  const we=addDays(w,6), ss=sessList(o.sessions).filter(s=>s.date>=w && s.date<=we);
  const lifts=ss.filter(s=>s.type==='lift' && (s.entries||[]).length);
  if(!lifts.length) return null;
  const chk=checkinsOf(o.changes).filter(c=>c.date>=w && c.date<=we);
  if(chk.some(c=>c.readiness==='very')) return false;
  if(chk.filter(c=>c.readiness==='sore').length>1) return false;
  if((o.changes||[]).some(c=>c && c.change && c.change.week===w && !String(c.id).startsWith('chk:') && (c.change.recovery||c.change.reduced))) return false;
  if(lifts.some(s=>s.reduced)) return false;
  if(lifts.length < Math.ceil(weekLiftCount(prog,w)*2/3)) return false;
  return groupLoads(volumeOf(lifts).credits).legs <= LEG_CAP[level||'regular'];
}
/* Volume stage. Returning: r1 (returning volume), r2 (optional accessories back at 2 sets), then regular volume.
   Each step needs 2 qualifying weeks; poor weeks hold the stage and time passing alone never moves it. Hold
   (rampHold) stops counting from that week. Regular and Higher are reg and hi. Groups (legs, push, pull) not
   trained for 21+ days are "fresh" and use returning set counts until they have 2 qualifying weeks again. */
function volumeFor(prog, o, ws){
  const c=configOn(prog, ws), lv=c.level;
  // Nothing saved yet: the original plan exactly as it was (no automatic volume changes).
  if(c.implicit) return {level:lv, stage:'reg', qualifying:0, fresh:{}, held:false};
  let stage = lv==='higher' ? 'hi' : 'reg', q=0;
  if(lv==='returning'){
    const since=weekStartOf(c.levelSince||ws, c.weekStart), hold=c.rampHold ? weekStartOf(c.rampHold, c.weekStart) : null;
    for(let w=since; w<ws; w=addDays(w,7)){ if(hold && w>=hold) break; if(weekQualifies(prog,o,w,lv)) q++ }
    stage = q>=4 ? 'reg' : q>=2 ? 'r2' : 'r1';
  }
  const fresh={};
  const ss=sessList(o.sessions).filter(s=>s.type==='lift' && s.date<ws).sort((a,b)=>a.date<b.date?-1:1);
  Object.keys(GROUPS).forEach(g=>{
    const dates=[...new Set(ss.filter(s=>groupLoads(volumeOf([s]).credits)[g]>=3).map(s=>s.date))];
    if(!dates.length){ fresh[g]=!ss.length ? false : true; return }        // no history at all: nothing to compare
    if(daysBetween(dates[dates.length-1], ws)>21){ fresh[g]=true; return }
    let i=dates.length-1; while(i>0 && daysBetween(dates[i-1],dates[i])<=21) i--;
    if(i===0){ fresh[g]=false; return }                                     // trained steadily since the first session
    let n=0; for(let w=weekStartOf(dates[i], c.weekStart); w<ws; w=addDays(w,7)){
      if(dates.some(d=>d>=w && d<=addDays(w,6)) && weekQualifies(prog,o,w,lv)) n++ }
    fresh[g]=n<2;
  });
  return {level:lv, stage, qualifying:q, fresh, held:!!c.rampHold};
}

/* ---------- resolving a program into workouts ---------- */
function structureOf(id, settings){ const b=EXMAP[id]; return (settings&&settings[id]&&settings[id].structure) || (b&&b.prog&&b.prog.s) || 'straight' }
/* One exercise of a workout at a volume stage. Pyramid and top-set lifts keep their structure: Returning starts the
   pyramid one set later (bench 10·8·6·5 -> 8·6·5, the top set unchanged) and uses one back-off. */
function exDef(id, sets, opt, stage, prefs, settings, edit){
  const base=EXMAP[id]; if(!base) return null;
  const avoid=(prefs&&prefs.avoid)||[], s=structureOf(id, settings), low = stage==='r1' || stage==='r2';
  let use=(prefs&&prefs.use||{})[id];
  if(use && (!EXMAP[use] || avoid.includes(use) || slotOf(use)!==id)) use=null;
  if(!use && avoid.includes(id)){ use=(ALTS[id]||[]).map(n=>altId(id,n)).find(a=>!avoid.includes(a)); if(!use) return null }
  const d={...base, id, slot:id, opt:!!opt, muscles:MUSCLES[id]||{}};
  if(use) d.use=use;
  if(s==='pyramid' && base.prog && base.prog.s==='pyramid'){
    let pat=base.prog.pattern.slice(); if(low && pat.length>=3) pat=pat.slice(1);
    d.prog={...base.prog, pattern:pat}; d.sets=pat.length;
  } else if(s==='topback' && base.prog && base.prog.s==='topback'){
    const b = low ? 1 : base.prog.backSets; d.prog={...base.prog, backSets:b}; d.sets=1+b;
  } else {
    if(stage==='r1'){ if(opt && !(edit&&edit.keep)) return null; d.sets=Math.max(2,sets-1) }
    else if(stage==='r2') d.sets = opt ? 2 : Math.max(2,sets-1);
    else if(stage==='hi') d.sets=Math.min(5,sets+1);
    else d.sets=sets;
    if(edit && edit.sets) d.sets=edit.sets;   // your own set count wins
    if(s!==((base.prog&&base.prog.s)||'straight')){ delete d.prog }
  }
  return d;
}
/* Every workout of a program at a volume, with your edits and exercise preferences. */
function workoutsFor(cfg, vol, settings){
  const c=normalize(cfg), t=TEMPLATES[c.template], f=t.freq[c.lifts], out={};
  f.w.forEach(key=>{
    const adj=(f.adjust||{})[key]||{}, ed=c.edits[key]||{};
    let list=W[key].ex.map(([id,n,opt])=>[id, (adj.sets||{})[id]!=null?adj.sets[id]:n, opt]).filter(([id])=>!(adj.remove||[]).includes(id));
    (adj.add||[]).forEach(([id,n,opt,after])=>{ const i=list.findIndex(x=>x[0]===after); list.splice(i<0?list.length:i+1,0,[id,n,opt]) });
    list=list.filter(([id])=>!(ed.remove||[]).includes(id));
    (ed.add||[]).forEach(a=>{ if(EXMAP[a.id] && !list.some(x=>x[0]===a.id)) list.push([a.id, a.sets||3, 0]) });
    const ex=list.map(([id,n,opt])=>{
      const g=GROUP_OF[primaries(id)[0]], st = vol && vol.fresh && vol.fresh[g] && (vol.stage==='reg'||vol.stage==='hi') ? 'r1' : (vol?vol.stage:'reg');
      return exDef(id, n, opt, st, c.prefs, settings, {sets:(ed.sets||{})[id], keep:(ed.add||[]).some(a=>a.id===id)});
    }).filter(Boolean);
    out[key]={key, name:W[key].name, type:'lift', ex};
  });
  return out;
}
/* The four original workouts as plan.js has them, for old Watch builds and old sessions. */
function classicWorkouts(){
  const out={};
  ['upperA','lowerA','upperB','lowerB'].forEach(k=>{ out[k]={key:k, name:W[k].name, type:'lift', ex:W[k].ex.map(([id,n,opt])=>({...EXMAP[id], id, slot:id, sets:n, opt:!!opt, muscles:MUSCLES[id]||{}}))} });
  return out;
}

/* ---------- the week ---------- */
const orderDays = (days, start) => days.slice().sort((a,b)=>((a-start+7)%7)-((b-start+7)%7));
/* The program's own week: workouts on your lifting days (in order, from the chosen rotation) and runs. */
function baseWeek(cfg, ws, workouts){
  const c=normalize(cfg), f=TEMPLATES[c.template].freq[c.lifts], days=orderDays(c.days, c.weekStart), n=f.w.length;
  const occs=[];
  days.forEach((d,i)=>{ const key=f.w[(i+(c.rotation||0))%n], date=addDays(ws, (d-c.weekStart+7)%7);
    occs.push({occ:`${ws}:${key}:1`, key, date, type:'lift', name:(workouts&&workouts[key]?workouts[key].name:W[key].name), auto:true}) });
  orderDays((c.runs||[]).map(r=>r.dow), c.weekStart).forEach((d,i)=>{
    const r=c.runs.find(x=>x.dow===d), key=i===0?'run':'run'+(i+1), date=addDays(ws,(d-c.weekStart+7)%7);
    occs.push({occ:`${ws}:${key}:1`, key, date, type:'run', name:RUN_KINDS[r.kind]||'Run', runKind:r.kind||'easy', optional:!!r.optional, auto:true});
  });
  return occs.sort((a,b)=>a.date<b.date?-1:a.date>b.date?1:a.type==='lift'?-1:1);
}
const changeList = (changes, ws) => (changes||[]).filter(c=>c && c.change && c.change.week===ws && !String(c.id).startsWith('chk:'));
/* A reduced workout: optional accessories out, straight sets with 3+ sets lose one, top-set lifts lose one back-off
   if they have two or more. Pyramids keep every set (their sets are tied to their structure). Kept sets are always
   the first ones, so targets stay the same. */
function reduceWorkout(workout, only){
  return exList(workout, only).filter(e=>!e.opt).map(e=>{
    let n=e.sets;
    if(e.prog && e.prog.s==='topback'){ if(e.prog.backSets>=2) n=e.sets-1 }
    else if(!(e.prog && e.prog.s==='pyramid') && e.sets>=3) n=e.sets-1;
    return {id:e.id, sets:n};
  });
}

/* Everything one week shows: occurrences with status (done / today / upcoming / missed / skipped / recovery), the
   sessions they match, extras, warnings, and actual sets and credits.
   o = {prog, changes, sessions, today, weekStart?, date?, settings?} */
function weekSchedule(o){
  const c0=configOn(o.prog, o.date||o.today), ws=o.weekStart || weekStartOf(o.date||o.today, c0.weekStart), we=addDays(ws,6);
  const cfg=configOn(o.prog, ws), vol=volumeFor(o.prog, o, ws), workouts=workoutsFor(cfg, vol, o.settings);
  const all={...classicWorkouts(), ...workoutsFor(cfg, vol, o.settings)};
  let occs=baseWeek(cfg, ws, workouts);
  changeList(o.changes, ws).forEach(({id, change:ch})=>{
    if(ch.add){ if(occs.some(x=>x.occ===id)) return;
      occs.push({occ:id, key:ch.key, date:ch.date, type:ch.type||(baseKey(ch.key)==='run'?'run':'lift'), name:ch.easier ? (RUN_KINDS[ch.runKind]||'Run')+' (shorter)' : ch.name||(all[ch.key]?all[ch.key].name:ch.key),
        ex:ch.ex||null, runKind:ch.runKind, optional:!!ch.optional, auto:ch.source==='auto', manual:ch.source==='manual', added:true, source:ch.source, note:ch.note||null}); }
    const x=occs.find(y=>y.occ===id); if(!x) return;
    if(ch.removed) x.removed=true;
    if(ch.date && ch.date!==x.date && !ch.add){ x.movedFrom=x.date; x.date=ch.date }
    if(ch.skipped) x.skipped=true;
    if(ch.recovery) x.recovery=true;
    if(ch.reduced) x.reduced=true;
    if(ch.ex && !ch.add) x.ex=ch.ex;
    if(ch.runKind && !ch.add && x.type==='run'){ x.runKind=ch.runKind; x.name=(RUN_KINDS[ch.runKind]||'Run')+(ch.easier?' (shorter)':'') }
    if(ch.key && ch.swap) { x.key=ch.key; x.name=all[ch.key]?all[ch.key].name:x.name }
    if(ch.source==='manual'){ x.manual=true; x.auto=false } else if(ch.source==='readiness') x.readiness=true;
  });
  occs=occs.filter(x=>!x.removed && x.date>=ws && x.date<=we);
  // Match sessions: an occurrence id first, then (older sessions without one) the same workout in date order.
  const ss=sessList(o.sessions).filter(s=>s.date>=ws && s.date<=we).sort((a,b)=>a.date<b.date?-1:a.date>b.date?1:(a.id<b.id?-1:1));
  const extras=[];
  ss.forEach(s=>{ if(s.occ){ const x=occs.find(y=>y.occ===s.occ && !y.done); if(x) x.done=s } });
  ss.forEach(s=>{
    if(occs.some(y=>y.done===s)) return;
    if(!s.occ && (s.type==='lift'||s.type==='run')){
      const k=baseKey(s.session), x=occs.filter(y=>!y.done && (s.type==='run' ? y.type==='run' : baseKey(y.key)===k)).sort((a,b)=>a.date<b.date?-1:1)[0];
      if(x){ x.done=s; return }
    }
    extras.push(s);
  });
  occs.forEach(x=>{
    x.status = x.done ? 'done' : x.skipped ? 'skipped' : x.recovery ? 'recovery' : x.date<o.today ? 'missed' : x.date===o.today ? 'today' : 'upcoming';
    if(x.type==='lift' && x.reduced && !x.done) x.ex=reduceWorkout(all[x.key], x.ex);
  });
  occs.sort((a,b)=>a.date<b.date?-1:a.date>b.date?1:a.type==='lift'?-1:1);
  const done=ss.filter(s=>s.type==='lift');
  const sched={weekStart:ws, config:cfg, volume:vol, workouts:all, occs, extras, actual:volumeOf(done)};
  sched.warnings=warningsFor(sched, cfg.level);
  // A long run or intervals on the day of, or the day after, a "very sore legs" check-in.
  checkinsOf(o.changes).filter(c=>c.readiness==='very' && (c.area||'legs')!=='upper').forEach(c=>{
    occs.filter(x=>x.type==='run' && !x.done && x.status!=='skipped' && x.status!=='recovery' && x.runKind!=='easy' && [0,1].includes(daysBetween(c.date,x.date)))
      .forEach(x=>sched.warnings.push({type:'sore', occs:[x.occ], text:`${x.name} ${x.date===c.date?'today':'the day after'} very sore legs. An easy run (or rest) is kinder.`}));
  });
  return sched;
}

/* ---------- recovery checks ---------- */
/* Each lift and run of a week as {date, occ, name, loads, kind}: actual credits for done workouts, planned ones for
   the rest; skipped, recovery and missed workouts did not happen. */
function itemsOf(sched){
  const items=[];
  sched.occs.forEach(x=>{
    if(x.status==='skipped'||x.status==='recovery'||x.status==='missed') return;
    if(x.type==='run'){ if(!x.optional || x.done) items.push({date:x.date, occ:x.occ, name:x.name, run:x.runKind||'easy'}); return }
    const cr = x.done ? volumeOf([x.done]).credits : plannedVolume(sched.workouts[x.key], x.ex).credits;
    items.push({date:x.date, occ:x.occ, name:x.name, loads:groupLoads(cr), credits:cr});
  });
  sched.extras.filter(s=>s.type==='lift').forEach(s=>{ const cr=volumeOf([s]).credits; items.push({date:s.date, occ:null, name:s.name||s.session, loads:groupLoads(cr), credits:cr}) });
  return items.sort((a,b)=>a.date<b.date?-1:1);
}
const GROUP_NAME = {legs:'leg', push:'push', pull:'pull'};
function warningsFor(sched, level){
  const items=itemsOf(sched), lifts=items.filter(i=>i.loads), dem=DEMANDING[level]||12, out=[];
  for(let i=0;i<lifts.length;i++) for(let j=i+1;j<lifts.length;j++){
    const a=lifts[i], b=lifts[j], gap=daysBetween(a.date,b.date);
    Object.keys(GROUPS).forEach(g=>{
      if(a.loads[g]>=dem && b.loads[g]>=dem && gap<SPACE[g])
        out.push({type:'spacing', group:g, occs:[a.occ,b.occ], text:`${a.name} and ${b.name} are ${gap===0?'on the same day':gap+' day'+(gap>1?'s':'')+' apart'}. Demanding ${GROUP_NAME[g]} days need ${SPACE[g]}.`});
      else if(gap===1 && a.loads[g]>=4 && b.loads[g]>=4 && !(a.loads[g]>=dem && b.loads[g]>=dem))
        out.push({type:'b2b', group:g, occs:[a.occ,b.occ], soft:true, text:`${a.name} and ${b.name} both train ${GROUP_NAME[g]} muscles on back-to-back days.`});
    });
  }
  const legs=r1(lifts.reduce((s,i)=>s+i.loads.legs,0));
  if(legs>(LEG_CAP[level]||40)) out.push({type:'legvolume', text:`This week has ${legs} leg sets (credited). That is a lot for your level (${LEG_CAP[level]||40}).`});
  items.filter(i=>i.run).forEach(r=>{
    const next=lifts.filter(l=>daysBetween(r.date,l.date)===1), prev=lifts.filter(l=>daysBetween(l.date,r.date)===1);
    if(r.run==='long') next.filter(l=>l.loads.legs>=dem).forEach(l=>out.push({type:'run', occs:[r.occ,l.occ], text:`Long run the day before ${l.name}, a demanding leg day.`}));
    if(r.run==='intervals'){
      next.filter(l=>l.loads.legs>=6).forEach(l=>out.push({type:'run', occs:[r.occ,l.occ], text:`Intervals the day before ${l.name}. Hard runs tire your legs.`}));
      prev.filter(l=>l.loads.legs>=dem).forEach(l=>out.push({type:'run', occs:[l.occ,r.occ], text:`Intervals the day after ${l.name}, a demanding leg day.`}));
    }
  });
  return out;
}
/* Which groups are off-limits on a date, given the other items of the week and any soreness check-ins.
   Easy runs never block anything; a long run or intervals the day before blocks leg work; intervals the day after
   block demanding leg work (handled as leg work here, to stay simple). */
function blockedOn(date, items, level, checkins, legsPlanned){
  const dem=DEMANDING[level]||12, out={};
  items.forEach(i=>{
    const gap=daysBetween(i.date, date);
    if(i.loads) Object.keys(GROUPS).forEach(g=>{
      if(i.loads[g]>=dem && Math.abs(gap)>0 && Math.abs(gap)<SPACE[g]) out[g]=`recovering from ${i.name} on ${DOW_NAME[dow(i.date)]}`;
      else if(Math.abs(gap)===1 && i.loads[g]>=4 && !out[g]) out[g]=`${i.name} is the day ${gap>0?'before':'after'}`;
    });
    if(i.run && i.run!=='easy' && (gap===1 || (i.run==='intervals' && gap===-1))) out.legs=out.legs||`${RUN_KINDS[i.run].toLowerCase()} on ${DOW_NAME[dow(i.date)]}`;
  });
  (checkins||[]).forEach(c=>{
    if(c.readiness!=='very' && c.readiness!=='sore') return;
    const gap=daysBetween(c.date, date); if(gap<0 || gap>(c.readiness==='very'?1:0)) return;
    const gs = c.area==='upper' ? ['push','pull'] : c.area==='all' ? ['legs','push','pull'] : ['legs'];
    gs.forEach(g=>{ out[g]=`sore ${c.area==='upper'?'upper body':c.area==='all'?'all over':'legs'}` });
  });
  const legs7=r1(items.filter(i=>i.loads && daysBetween(i.date,date)>0 && daysBetween(i.date,date)<7).reduce((s,i)=>s+i.loads.legs,0));
  if(legsPlanned!=null && legs7+legsPlanned>(LEG_CAP[level]||40)) out.legs=out.legs||`${legs7} leg sets in the last 7 days`;
  return out;
}

/* ---------- recovery days and skips ---------- */
/* Two different decisions, built the same way wherever they are made (readiness check or Plan tab):
   - Recovery day: you need more physical recovery. Saves why and which muscle groups (from that day's readiness
     check when there is one) plus the groups the workout would have trained. It holds the Returning stage that week,
     and repeated recovery days for the same groups lead to a suggestion (recoveryAdvice), never an automatic cut.
   - Skip: not doing it for another reason (time, travel). It leaves the schedule, keeps its skipped status, and is
     never read as a recovery problem.
   Neither creates a session, so history and progression are untouched; neither counts toward the week's goal. */
const AREA_GROUPS = {legs:['legs'], upper:['push','pull'], all:['legs','push','pull']};
function trainedGroups(sched, x){
  if(!x) return [];
  if(x.type==='run') return ['legs'];
  const w=sched.workouts[x.key]; if(!w) return [];
  return Object.entries(groupLoads(plannedVolume(w, x.ex).credits)).filter(([,v])=>v>=4).map(([g])=>g);
}
function recoveryPatch(sched, occId, changes){
  const x=sched.occs.find(y=>y.occ===occId); if(!x) return null;
  const c=checkinsOf(changes).find(k=>k.date===x.date && (k.readiness==='sore'||k.readiness==='very'));
  return {recovery:true, skipped:false, on:x.date, reason: c ? (c.readiness==='very'?'very sore':'a little sore') : 'needed more recovery',
    groups: c ? AREA_GROUPS[c.area||'legs'] : null, trained: trainedGroups(sched, x)};
}
function skipPatch(sched, occId){
  const x=sched.occs.find(y=>y.occ===occId); if(!x) return null;
  return {skipped:true, recovery:false, on:x.date, reason:null, groups:null, trained:null};
}
const GROUP_WORDS = {legs:'leg', push:'chest, shoulder and triceps', pull:'back and biceps'};
/* Suggestions (never automatic changes) when recovery days keep landing on the same muscle groups: 2 or more in the
   last 4 weeks. Uses the sore groups from the readiness check, else the groups the workout trains. */
function recoveryAdvice(changes, today){
  const since=addDays(today,-27), per={};
  (changes||[]).forEach(c=>{ const ch=c&&c.change; if(!ch || !ch.recovery || String(c.id).startsWith('chk:')) return;
    const d=ch.on||ch.date; if(!d || d<since || d>today) return;
    const gs=(ch.groups&&ch.groups.length) ? ch.groups : (ch.trained||[]);
    gs.forEach(g=>{ (per[g] ||= new Set()).add(d) }); });
  return Object.entries(per).filter(([,ds])=>ds.size>=2).map(([g,ds])=>({group:g, count:ds.size,
    text:`${ds.size} recovery days for your ${GROUP_WORDS[g]||g} muscles in the last 4 weeks. Consider fewer ${GROUP_WORDS[g]||g} sets (the Returning level does this) or more days between those workouts.`}));
}

/* A suggestion (never an automatic change) when the plan keeps asking for more than gets done: in at least 3 of the
   last 4 full weeks, under 75% of the planned workouts were done. Planned = the week's goal plus skips (skips and
   missed workouts are scheduling, so they count as planned-but-not-done); recovery days are left out, since those are
   about recovery, not the schedule. Suggests a lifting-day count near what you have actually been doing. */
function scheduleAdvice(prog, o, today){
  const cur=configOn(prog, today), ws=weekStartOf(today, cur.weekStart), weeks=[];
  // Only full weeks after the first logged workout count (weeks before using the app are not "missed").
  const first=sessList(o.sessions).map(x=>x.date).sort()[0]; if(!first) return null;
  const from = weekStartOf(first, cur.weekStart)===first ? first : addDays(weekStartOf(first, cur.weekStart),7);
  for(let i=1;i<=4;i++){
    const w=addDays(ws,-7*i); if(w<from) break;
    const s=weekSchedule({...o, prog, today, weekStart:w});
    const planned=s.occs.filter(x=>!x.optional && x.status!=='recovery'), done=planned.filter(x=>x.status==='done');
    if(!planned.length) continue;
    weeks.push({w, planned:planned.length, done:done.length, lifts:done.filter(x=>x.type==='lift').length, short: done.length < 0.75*planned.length});
  }
  if(weeks.filter(x=>x.short).length<3) return null;
  const avg=k=>weeks.reduce((a,x)=>a+x[k],0)/weeks.length, t=TEMPLATES[cur.template], freqs=Object.keys(t.freq).map(Number);
  const target=Math.max(2, Math.round(avg('lifts')));
  const fit=freqs.filter(n=>n<cur.lifts && n>=target).sort((a,b)=>a-b)[0];
  const idea = fit ? `${fit} lifting days instead of ${cur.lifts}` : target<=2 ? 'Strength + Running with 2 lifting days' : target<=3 && cur.lifts>3 ? 'Balanced Fitness (3 lifting days)' : 'fewer scheduled days';
  return {weeks:weeks.length, short:weeks.filter(x=>x.short).length, avgDone:Math.round(avg('done')*10)/10, avgPlanned:Math.round(avg('planned')*10)/10, suggest:fit||null,
    text:`Over the last ${weeks.length} weeks you finished about ${Math.round(avg('done'))} of ${Math.round(avg('planned'))} planned workouts a week. A lighter schedule might fit better, for example ${idea}. You can change it in Program settings.`};
}

/* ---------- readiness check ---------- */
/* What to suggest when a scheduled lift comes with soreness. Ready: nothing. A little sore: start as planned, with
   Reduce offered. Very sore: Move to the first later day this week with no lift that creates no new warning and is
   clear of the sore area, else Reduce. Never changes weights. */
function readiness(sched, occId, answer, today, area){
  const x=sched.occs.find(y=>y.occ===occId); if(!x) return null;
  if(answer==='ready') return {answer, occ:occId, recommend:null, actions:[]};
  if(x.type==='run'){
    // Runs: an easy run is gentle, a long run or intervals is not. Very sore legs never get a hard run recommended.
    const hard=x.runKind==='long'||x.runKind==='intervals', legs=(area||'legs')!=='upper';
    const moveTo=moveTarget(sched, occId, today, [{date:today, readiness:answer, area:area||'legs'}]);
    const recommend = !legs ? 'start' : answer==='sore' ? (hard?'easier':'start') : (hard?'easier':'recovery');
    return {answer, occ:occId, run:true, hard, moveTo, recommend, actions:['start', ...(hard?['easier']:[]), 'move', 'recovery', 'skip']};
  }
  const base={answer, occ:occId, actions:['start','move','reduce','recovery','skip']};
  const moveTo=moveTarget(sched, occId, today, answer==='very' ? [{date:today, readiness:'very', area:area||'legs'}] : []);
  return {...base, moveTo, recommend: answer==='sore' ? 'start' : moveTo ? 'move' : 'reduce'};
}
function moveTarget(sched, occId, today, checkins){
  const x=sched.occs.find(y=>y.occ===occId), we=addDays(sched.weekStart,6); if(!x) return null;
  const level=sched.config.level, before=new Set(sched.warnings.map(w=>w.text));
  for(let d=addDays(today,1); d<=we; d=addDays(d,1)){
    if(sched.occs.some(y=>y!==x && y.type===x.type && y.date===d && y.status!=='skipped' && y.status!=='recovery' && !(y.optional&&!y.done))) continue;
    const moved={...sched, occs:sched.occs.map(y=>y===x?{...y, date:d, status:'upcoming'}:y)};
    const fresh=warningsFor(moved, level).filter(w=>!before.has(w.text) && (w.occs||[]).includes(occId));
    if(fresh.length) continue;
    if(x.type==='run'){
      if(x.runKind!=='easy' && blockedOn(d, [], level, checkins, null).legs) continue;
      return d;
    }
    const pv=plannedVolume(sched.workouts[x.key], x.ex), loads=groupLoads(pv.credits);
    const bl=blockedOn(d, itemsOf(moved).filter(i=>i.occ!==occId), level, checkins, loads.legs);
    if(Object.keys(bl).some(g=>loads[g]>=4)) continue;
    return d;
  }
  return null;
}

/* ---------- switching programs mid-week ---------- */
/* Switch programs. Two ways, always previewed first; completed workouts, recovery days and skips are never touched:
   - mode 'next' (start next week): this week stays exactly as it is; the new program starts on the next week start.
   - mode 'adapt' (adapt this week): the new program takes over now. Completed workouts count toward its weekly muscle
     targets, whatever program they came from, and the rest of this week is planned from what is still missing.
   ('now' / startNow: the new program's own week from today, kept for older callers.)
   o = {prog, next (new settings), changes, sessions, today, settings?, sore?: 'legs'|'upper'|'all', mode?,
        keep?: {occ: false}}   keep: workouts you moved, added or changed after a readiness check stay unless false.
   Rules: a major muscle (chest, back, shoulders, quads, glutes, hamstrings) has a gap below 80% of target and at
   least 3 credits short. Each remaining lifting day of the new program gets the new workout that covers the most
   gap, without exercises for groups that are still recovering (spacing, back-to-back, hard runs, soreness, weekly
   leg cap) or whose main muscles are already covered. A day needs at least 6 useful sets and 3 gap credits,
   at most ceil(lifts a week x days left / 7) workouts are added, and finishing the week below target is fine.
   The new program's normal schedule starts next week unless startNow. */
function planSwitch(o){
  const today=o.today, oldCfg=configOn(o.prog, today), ws=weekStartOf(today, oldCfg.weekStart), we=addDays(ws,6);
  const next=normalize({...o.next, levelSince: o.next.level==='returning' && (oldCfg.level!=='returning' || !o.next.levelSince) ? today : o.next.levelSince});
  const mode = o.startNow ? 'now' : o.mode || 'next';
  const old=weekSchedule({...o, weekStart:ws});
  const keep=o.keep||{};
  const future=old.occs.filter(x=>!x.done && (x.status==='today'||x.status==='upcoming'));
  const mine=x=>x.manual || x.readiness;
  const conflicts=future.filter(mine).map(x=>({occ:x.occ, name:x.name, date:x.date, type:x.type, keep:keep[x.occ]!==false,
    why: x.added ? 'You added this workout' : x.movedFrom ? `You moved this from ${DOW_NAME[dow(x.movedFrom)]}` : x.readiness ? 'Changed after a readiness check' : 'You changed this workout'}));
  const kept=future.filter(x=>mine(x) && keep[x.occ]!==false), replaced=future.filter(x=>!kept.includes(x));
  const held=old.occs.filter(x=>x.status==='recovery'||x.status==='skipped').map(x=>x.occ);
  const doneS=sessList(o.sessions).filter(s=>s.date>=ws && s.date<=today && s.type==='lift');
  const before=volumeOf(doneS);
  // An earlier switch still waiting for next week is replaced by this one, never stacked on it.
  const past=((o.prog&&o.prog.past)||[]).filter(p=>p && p.until && p.until<ws);
  const nextCfg={...next, startedOn: mode==='now' ? ws : addDays(we,1)};
  if(mode==='adapt') nextCfg.adaptWeek=ws; else delete nextCfg.adaptWeek;
  const nextProg={config:nextCfg, past:[...past, {config:oldCfg, until: mode==='now' ? addDays(ws,-1) : we}]};
  const nextWeek=weekSchedule({...o, prog:nextProg, weekStart:addDays(we,1)});
  if(mode==='next'){
    // This week's earlier switch changes (from an adapted week) stay as they are; nothing new is written.
    return {mode, startNow:false, weekStart:ws, startsOn:addDays(we,1), prog:nextProg, rows:[], conflicts:[], kept:future.map(x=>x.occ), replaced:[], held,
      added:[], before, days:previewDays(old, old, ws, today), nextWeek:nextWeek.occs, warnings:old.warnings};
  }
  if(mode==='now'){
    const sched=weekSchedule({...o, prog:nextProg, changes:(o.changes||[]).filter(c=>!c.change||c.change.week!==ws), weekStart:ws});
    const rows=kept.map(x=>({id:`${ws}:m:${x.key}:1`, change:{week:ws, add:true, key:x.key, date:x.date, type:x.type, name:x.name, ex:x.ex||null, runKind:x.runKind, source:'manual'}}));
    return {mode, startNow:true, weekStart:ws, prog:nextProg, rows, conflicts, kept:kept.map(x=>x.occ), held, before, days:previewDays(old, sched, ws, today), nextWeek:nextWeek.occs, warnings:sched.warnings};
  }
  const vol=volumeFor(nextProg, o, addDays(we,1)), workouts=workoutsFor(next, vol, o.settings);
  const order=TEMPLATES[next.template].freq[next.lifts].w;
  const target=emptyCredits(); order.forEach(k=>{ const v=plannedVolume(workouts[k]).credits; MUSCLE_LIST.forEach(m=>target[m]=r1(target[m]+v[m])) });
  const credit={...before.credits};
  const items=itemsOf({...old, occs:old.occs.filter(x=>x.done || kept.includes(x))});
  kept.filter(x=>x.type==='lift').forEach(x=>{ const v=plannedVolume(old.workouts[x.key], x.ex).credits; MUSCLE_LIST.forEach(m=>credit[m]=r1(credit[m]+v[m])) });
  const gapOf = m => MAJOR.includes(m) && credit[m] < 0.8*target[m] && target[m]-credit[m] >= 3;
  const covered = m => MAJOR.includes(m) ? !gapOf(m) : credit[m] >= target[m];
  const checkins=[...checkinsOf(o.changes), ...(o.sore?[{date:today, readiness:'very', area:o.sore}]:[])];
  const liftToday=doneS.some(s=>s.date===today);
  const cap=Math.max(0, Math.ceil(order.length*(daysBetween(today,we)+1)/7) - kept.filter(x=>x.type==='lift').length);
  const newDays=orderDays(next.days, oldCfg.weekStart).map(d=>addDays(ws,(d-oldCfg.weekStart+7)%7)).filter(d=>d>=today && d<=we).sort();
  const added=[], dayNotes={};
  // The new program's runs on the days left come first (their days are fixed), so hard runs shape the lifting days.
  const usedRuns=new Set([...sessList(o.sessions).filter(s=>s.date>=ws && s.date<=we && s.type==='run').map(s=>s.session), ...kept.map(x=>x.key)]);
  orderDays((next.runs||[]).map(r=>r.dow), oldCfg.weekStart).forEach(dw=>{
    const d=addDays(ws,(dw-oldCfg.weekStart+7)%7), r=next.runs.find(x=>x.dow===dw); if(d<today) return;
    if(sessList(o.sessions).some(s=>s.date===d && s.type==='run')) return;
    let i=1; while(usedRuns.has(i===1?'run':'run'+i)) i++;
    const key=i===1?'run':'run'+i; usedRuns.add(key);
    // A long run or intervals right after reported leg soreness becomes an easy run (shown in the preview).
    let kind=r.kind||'easy', note=null;
    if(kind!=='easy' && blockedOn(d, [], next.level, checkins, null).legs){ note=`${RUN_KINDS[kind]} made easy: ${blockedOn(d, [], next.level, checkins, null).legs}`; kind='easy' }
    added.push({occ:`${ws}:t:${key}:1`, key, date:d, type:'run', name:RUN_KINDS[kind]||'Run', runKind:kind, optional:!!r.optional, note});
    if(!r.optional) items.push({date:d, occ:`${ws}:t:${key}:1`, name:RUN_KINDS[kind]||'Run', run:kind});
  });
  for(let d=today; d<=we; d=addDays(d,1)) if(!newDays.includes(d) && old.occs.some(x=>x.date===d && x.type==='lift' && !x.done)) dayNotes[d]='Not a lifting day in the new program';
  let n=0;
  newDays.forEach(d=>{
    if(d===today && liftToday){ dayNotes[d]='You already lifted today'; return }
    if(kept.some(x=>x.type==='lift' && x.date===d)){ dayNotes[d]='Keeps the workout you scheduled'; return }
    if(n>=cap){ dayNotes[d]='Enough added for the days left this week'; return }
    let best=null;
    order.forEach(k=>{
      const wk=workouts[k], keepEx=[], dropped=[];
      const legsAll=groupLoads(plannedVolume(wk).credits).legs;
      const bl=blockedOn(d, items, next.level, checkins, legsAll);
      wk.ex.forEach(e=>{
        const pr=primaries(e.id), gs=[...new Set(pr.map(m=>GROUP_OF[m]).filter(g=>g&&GROUPS[g]))];
        const why=gs.map(g=>bl[g]).find(Boolean);
        if(pr.every(covered)) dropped.push({id:e.id, name:EXMAP[e.use||e.id].name, why:'already covered this week'});
        else if(why) dropped.push({id:e.id, name:EXMAP[e.use||e.id].name, why});
        else keepEx.push(e);
      });
      const sets=keepEx.reduce((s,e)=>s+e.sets,0);
      const give=emptyCredits(); keepEx.forEach(e=>Object.entries(musclesOf(e.id)).forEach(([m,w])=>give[m]+=e.sets*w));
      const score=r1(MAJOR.filter(gapOf).reduce((s,m)=>s+Math.min(target[m]-credit[m], give[m]),0));
      if(score>=3 && sets>=6 && (!best || score>best.score)) best={key:k, keepEx, dropped, sets, score, give};
    });
    if(!best){ dayNotes[d]='Nothing useful left to train without crowding recovery'; return }
    const trimmed=best.keepEx.length<workouts[best.key].ex.length;
    const gaps=MAJOR.filter(gapOf).filter(m=>best.give[m]>0);
    added.push({occ:`${ws}:t:${best.key}:1`, key:best.key, date:d, type:'lift', name:workouts[best.key].name+(trimmed?' (adjusted)':''),
      ex: trimmed ? best.keepEx.map(e=>({id:e.id, sets:e.sets})) : null, sets:best.sets, dropped:best.dropped, covers:gaps});
    MUSCLE_LIST.forEach(m=>credit[m]=r1(credit[m]+best.give[m]));
    items.push({date:d, occ:`${ws}:t:${best.key}:1`, name:workouts[best.key].name, loads:groupLoads(best.give), credits:best.give});
    n++;
  });
  const rows=[
    ...replaced.filter(x=>!added.some(a=>a.occ===x.occ)).map(x=>({id:x.occ, change:{week:ws, removed:true, source:'auto'}})),
    ...added.map(x=>({id:x.occ, change:{week:ws, add:true, key:x.key, date:x.date, type:x.type, name:x.name, ex:x.ex||null, runKind:x.runKind, optional:x.optional||undefined, note:x.note||undefined, source:'auto'}})),
  ];
  const after={sets:before.sets+added.filter(x=>x.type==='lift').reduce((s,x)=>s+x.sets,0)+kept.filter(x=>x.type==='lift').reduce((s,x)=>s+plannedVolume(old.workouts[x.key],x.ex).sets,0), credits:credit};
  const newSched=weekSchedule({...o, prog:nextProg, changes:[...(o.changes||[]).filter(c=>!rows.some(r=>r.id===c.id)), ...rows], weekStart:ws});
  return {mode, startNow:false, weekStart:ws, prog:nextProg, rows, conflicts, kept:kept.map(x=>x.occ), replaced:replaced.map(x=>x.occ), held, added,
    before, after, target, gaps:MAJOR.filter(gapOf).map(m=>({muscle:m, short:r1(target[m]-credit[m])})),
    days:previewDays(old, newSched, ws, today, dayNotes, added), nextWeek:nextWeek.occs, warnings:newSched.warnings};
}
/* Before / after for each remaining day of the week, for the switch preview. */
function previewDays(old, neu, ws, today, notes, added){
  const out=[];
  for(let d=today; d<=addDays(ws,6); d=addDays(d,1)){
    const b=old.occs.filter(x=>x.date===d && x.status!=='done'), a=neu.occs.filter(x=>x.date===d && x.status!=='done');
    const done=old.occs.filter(x=>x.date===d && x.status==='done');
    out.push({date:d, done:done.map(x=>x.name), before:b.map(x=>({occ:x.occ, name:x.name, type:x.type, optional:!!x.optional, status:x.status})),
      after:a.map(x=>{ const ad=(added||[]).find(y=>y.occ===x.occ); return {occ:x.occ, name:x.name, type:x.type, optional:!!x.optional, ex:x.ex||null, status:x.status, dropped:(ad&&ad.dropped)||[], covers:(ad&&ad.covers)||[], note:(ad&&ad.note)||null} }),
      note:(notes||{})[d]||null});
  }
  return out;
}

/* Which program governs this week, and which (if any) is waiting to start. An adapted week belongs to the new
   program; a program chosen to start next week is "upcoming" until its start date, then simply current. */
function programStatus(prog, today){
  const cur=configOn(prog, today), ws=weekStartOf(today, cur.weekStart), latest=prog&&prog.config ? normalize(prog.config) : null;
  if(latest && latest.startedOn && latest.startedOn>today){
    if(latest.adaptWeek===ws) return {current:latest, adapted:true, from:cur, upcoming:null, startsOn:null};
    return {current:cur, adapted:false, upcoming:latest, startsOn:latest.startedOn};
  }
  return {current:cur, adapted:false, upcoming:null, startsOn:null};
}
/* The week's goal: scheduled workouts that are not optional and not set aside on purpose (recovery days, skips). */
const goalOf = sched => sched.occs.filter(x=>!x.optional && x.status!=='recovery' && x.status!=='skipped');

/* ---------- what the Watch gets ---------- */
function restSecs(txt){
  const m=/(\d+(?:\.\d+)?)(?:-(\d+(?:\.\d+)?))?\s*(min|sec)/.exec(txt||''); if(!m) return 90;
  const a=+m[1], b=m[2]?+m[2]:a, v=(a+b)/2; return Math.round(m[3]==='min'? v*60 : v);
}
/* Plans (progression.js) for every exercise and alternative of each workout, with the workout's own set counts. */
function plansFor(Progression, workouts, input){
  const out={};
  Object.values(workouts).forEach(wk=>{
    const ex={};
    wk.ex.forEach(e=>{
      [e.id, ...(ALTS[e.id]||[]).map(n=>altId(e.id,n))].forEach(id=>{
        const def = id===e.id ? e : {...EXMAP[id], sets:e.sets, reps:e.reps};
        const c=Progression.configFor(def, (input.settings||{})[id]);
        ex[id]=Progression.planFor(c, Progression.historyFor(input.sessions, id, {today:input.today}), input.today);
      });
    });
    out[wk.key]=ex;
  });
  return out;
}
/* Program, workouts and this week plus next week's occurrences, as the Watch caches them. */
function serve(o){
  const c=configOn(o.prog, o.today), ws=weekStartOf(o.today, c.weekStart);
  const a=weekSchedule({...o, weekStart:ws}), b=weekSchedule({...o, weekStart:addDays(ws,7)});
  const workouts={...b.workouts, ...a.workouts};   // this week's set counts for workouts in both weeks
  const wire={};
  Object.values(workouts).forEach(w=>{ wire[w.key]={name:w.name, type:'lift', exercises:w.ex.map(e=>({id:e.id, name:e.name, sets:e.sets, low:e.reps[0], high:e.reps[1], rest:e.rest, restSeconds:restSecs(e.rest),
    note:e.note||null, small:!!e.small, superset:e.superset||null, timed:!!e.timed, use:e.use||null, opt:!!e.opt,
    alts:(ALTS[e.id]||[]).map(n=>({id:altId(e.id,n), name:n}))}))} });
  const occ=x=>({occ:x.occ, key:x.key, date:x.date, type:x.type, name:x.name, status:x.status, optional:!!x.optional, runKind:x.runKind||null,
    reduced:!!x.reduced, ex:x.ex?x.ex.map(e=>({id:e.id, sets:e.sets})):null, doneId:x.done?x.done.id:null});
  const ps=programStatus(o.prog, o.today), pc=ps.current;
  return {program:{template:pc.template, name:TEMPLATES[pc.template].name, level:pc.level, levelName:LEVELS[pc.level], stage:a.volume.stage,
      upcoming: ps.upcoming ? {template:ps.upcoming.template, name:TEMPLATES[ps.upcoming.template].name, startsOn:ps.startsOn} : null},
    weekStart:ws, workouts:wire, occs:[...a.occs, ...b.occs].map(occ), allWorkouts:workouts};
}

/* Safe ids for workouts saved on two devices. Each workout has its own uid (made when it starts, kept through a
   handoff). If the session id (date-key) is already used by a different finished workout, this one moves to the
   next free key (upperA~2, upperA~3): nothing is overwritten and nothing is saved twice. Returns the new key, or
   null to keep the id. Older sessions have no uid; two without one are the same workout (an edit). */
function rekey(local, remote, taken){
  if(!remote || remote.status!=='complete' || (local.uid||null)===(remote.uid||null)) return null;
  const b=String(local.session).replace(/~\d+$/,''); let n=2;
  while(taken.has(`${local.date}-${b}~${n}`)) n++;
  return `${b}~${n}`;
}

/* The whole "plans" response the Watch caches: the original v1 plans (so older Watch builds keep working), plus
   plans for the program's workouts with their own set counts, the program, its workouts and two weeks of
   occurrences. o = {sessions, settings, today, prog, changes}. Used by the Edge Function and its parity check. */
function watchPayload(Progression, o){
  const out=Progression.buildPlans({sessions:o.sessions, settings:o.settings, today:o.today, plan:WP});
  const sv=serve(o);
  Object.assign(out.sessions, plansFor(Progression, sv.allWorkouts, o));
  out.program=sv.program; out.weekStart=sv.weekStart; out.workouts=sv.workouts; out.occs=sv.occs;
  return out;
}

/* Suggested day order for a program on your days: the first rotation of the workouts with no spacing warning. */
function bestRotation(cfg){
  const c=normalize(cfg), t=TEMPLATES[c.template], n=t.freq[c.lifts].w.length;
  if(t.fixedOrder) return 0;
  const ws='2030-01-07';
  for(let r=0;r<n;r++){
    const cc={...c, rotation:r}, s=weekSchedule({prog:{config:cc}, changes:[], sessions:[], today:addDays(ws,-1), weekStart:weekStartOf(ws,c.weekStart)});
    if(!s.warnings.some(w=>!w.soft)) return r;
  }
  return 0;
}

const P = {MUSCLE_LIST, MAJOR, GROUPS, SPACE, DEMANDING, LEG_CAP, LEVELS, RUN_KINDS, TEMPLATES, WORKOUTS:W, DOW_NAME,
  defaultConfig, normalize, configFor, configOn, addDays, dow, daysBetween, weekStartOf, baseKey, sessList,
  volumeOf, plannedVolume, groupLoads, exList, volumeFor, weekQualifies, workoutsFor, classicWorkouts, baseWeek,
  reduceWorkout, weekSchedule, warningsFor, itemsOf, blockedOn, readiness, moveTarget, planSwitch, plansFor, serve,
  bestRotation, restSecs, musclesOf, slotOf, rekey, watchPayload, programStatus, goalOf, recoveryPatch, skipPatch, recoveryAdvice, scheduleAdvice, AREA_GROUPS};
if(typeof module!=='undefined' && module.exports) module.exports=P;
globalThis.Programs=P;
})();
