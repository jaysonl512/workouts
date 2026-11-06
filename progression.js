/* Session's progression rules: deterministic, rules-based targets for every lift. No AI, no clock: "today" is
   always passed in, so the same history, settings and date always give the same plan.

   Used by the web app (index.html), by the Supabase Edge Function "plans" (which serves the Watch, whose plans
   are cached on the Watch so it works offline), and by tests/progression.test.js. The Watch has no formulas.

   Words used below
   - Working set: a logged set without wu:true (warm-ups never count for progression, volume or PRs).
   - Planned set {w, r}: the original target. A logged set stores what was done (w, r), the original target
     (pw, pr), and the target shown when it was logged (tw, tr), which differs only if it was edited.
   - Each plan carries a `state` that is saved with the exercise when the workout is saved (entry.prog). The next
     plan is worked out from that state and the sets actually logged against it.

   Results for a group of sets (all working sets; for top set + back-offs, the top set and the back-offs separately)
   - Incomplete: fewer working sets logged than planned. Hold. The missed streak does not change.
   - Otherwise each planned set gets a shortfall: reps short of its planned reps, and at least 1 if the set was done
     easier than planned (lighter, or with more assistance on assisted moves).
     Met: total 0. Borderline: no set more than 1 short and at most 2 short in total. Missed: anything else.
   - Met: progress (rules per structure). Borderline: hold, streak 0. Missed: hold; the second Missed in a row
     (Incomplete and deload sessions in between are skipped) steps the weight down once and resets the reps.
   - Ratings never change a result. Hard on a Met session blocks a weight increase (reps can still go up).
   - Met with every set done harder than planned by the same amount and every planned rep reached: the plan
     adopts that weight (same rep targets). Any other heavier set just counts as meeting its target.
   - Time off since the exercise was last done: up to 21 days normal; 22-42 repeat the last plan; 43-84 one
     step easier; over 84 about 90% of the weight (at least one step easier). Reps reset after a step down. */
(function(){
'use strict';

const EPS = 1e-9;
const DAY = 86400000;
const isAssistName = n => /\b(pull|chin)-?ups?\b/i.test(n||'');
const isPerArmName = n => /\b(single|one)-arm\b/i.test(n||'');

/* Equipment from an exercise name, for alternatives that have no eq of their own. */
function guessEquip(name){
  const n=(name||'').toLowerCase();
  if(isAssistName(n)) return 'assisted';
  if(/dumbbell|\bdb\b|arnold|hammer curl|goblet|bulgarian|lunge|step-up/.test(n)) return 'dumbbell';
  if(/plank|dead bug|hollow|nordic|sissy|sit-up|knee raise|ab wheel|\bdips\b|glute bridge|back extension/.test(n)) return 'bodyweight';
  if(/machine|leg press|hack squat|pec deck|smith/.test(n)) return 'machine';
  if(/cable|pushdown|crossover|face pull|pull-through|pulldown|rope|crunch/.test(n)) return 'cable';
  if(/barbell|bench|squat|deadlift|rack pull|good morning|ez-bar|skull|t-bar|landmine|overhead press|hip thrust|rdl|row/.test(n)) return 'barbell';
  return 'machine';
}

/* Everything the rules need about one exercise: plan defaults (plan.js), then the user's settings on top.
   settings: {structure?, equipment?, step?} from public.exercise_settings. */
function configFor(ex, settings){
  const s=settings||{}, base=ex.alt ? {} : (ex.prog||{});
  const eq = s.equipment || (!ex.alt && ex.eq) || guessEquip(ex.name);
  let structure = s.structure || base.s || 'straight';
  if(eq==='assisted' || eq==='bodyweight') structure='straight';
  const lo=ex.reps[0], hi=ex.reps[1], n=ex.sets;
  const step = +s.step>0 ? +s.step
    : eq==='dumbbell' ? 0                       // 0 = dumbbell rack: 2.5 lb up to 25, then 5 lb
    : (eq==='machine'||eq==='cable') ? (ex.small?2.5:5) : 5;
  const timed = !!ex.timed;
  const vf = ex.alt || ex.vf==null ? ((eq==='dumbbell' && !/goblet/i.test(ex.name)) || isPerArmName(ex.name) ? 2 : 1) : ex.vf;
  const c = {id:ex.id, name:ex.name, eq, structure, sets:n, lo, hi, step, timed, repStep:timed?5:1, vf,
    warmups: structure!=='straight'};
  if(structure==='pyramid'){
    c.pattern = base.s==='pyramid' && base.pattern && base.pattern.length===n ? base.pattern.slice()
      : Array.from({length:n},(_,i)=>Math.max(4, hi-2*i));
    c.gap = base.s==='pyramid' && base.gap ? base.gap : (eq==='barbell' ? 10 : 5);
  } else if(structure==='topback'){
    c.top = base.s==='topback' && base.top ? base.top.slice() : [lo, Math.min(hi, lo+2)];
    c.back = base.s==='topback' && base.back ? base.back.slice() : [lo+2, lo+4];
    c.backSets = base.s==='topback' && base.backSets ? base.backSets : Math.max(1, n-1);
    c.pct = base.s==='topback' && base.pct ? base.pct : 0.85;
  }
  return c;
}

/* ---------- available weights ---------- */
const fl = x => Math.floor(x+EPS), ce = x => Math.ceil(x-EPS);
function snapDown(c,x){                       // heaviest available weight at or below x
  if(x<=0) return 0;
  if(c.eq==='dumbbell' && !c.step) return x<25 ? fl(x/2.5)*2.5 : fl(x/5)*5;
  return fl(x/c.step)*c.step;
}
function snapUp(c,x){                         // lightest available weight at or above x
  if(x<=0) return 0;
  if(c.eq==='dumbbell' && !c.step) return x<=25 ? ce(x/2.5)*2.5 : ce(x/5)*5;
  return ce(x/c.step)*c.step;
}
function up(c,w){                             // next heavier available weight
  if(c.eq==='dumbbell' && !c.step) return w<25-EPS ? Math.min(25, fl(w/2.5)*2.5+2.5) : fl(w/5)*5+5;
  return fl(w/c.step)*c.step+c.step;
}
function down(c,w){                           // next lighter available weight (never below 0)
  if(w<=EPS) return 0;
  if(c.eq==='dumbbell' && !c.step) return w<=25+EPS ? Math.max(0, ce(w/2.5)*2.5-2.5) : Math.max(25, ce(w/5)*5-5);
  return Math.max(0, ce(w/c.step)*c.step-c.step);
}
/* Direction-aware: on assisted moves less assistance is harder. */
const assisted = c => c.eq==='assisted';
const harder = (c,w) => assisted(c) ? down(c,w) : up(c,w);
const easier = (c,w) => assisted(c) ? up(c,w) : down(c,w);
const snapEasy = (c,x) => assisted(c) ? snapUp(c,x) : snapDown(c,x);
const asHard = (c,a,b) => assisted(c) ? a<=b+EPS : a>=b-EPS;       // a is at least as hard as b
const harderBy = (c,a,b) => assisted(c) ? b-a : a-b;                 // how much harder a is than b
const lighterBy = (c,w,d) => assisted(c) ? w+d : Math.max(0, w-d);   // d easier than w

/* ---------- planned sets ---------- */
function backW(c,W){ return W==null ? null : Math.min(snapEasy(c, c.pct*W), easier(c,W)) }
function plannedSets(c,st){
  const W=st.W;
  if(c.structure==='pyramid'){
    const n=c.pattern.length;
    return c.pattern.map((p,i)=>{ const top=i===n-1;
      return {w: W==null?null:lighterBy(c,W,(n-1-i)*c.gap), r: top?st.T:p, k: top?'top':'ramp'} });
  }
  if(c.structure==='topback')
    return [{w:W, r:st.T, k:'top'}, ...Array.from({length:c.backSets},()=>({w:backW(c,W), r:st.Tb, k:'back'}))];
  return Array.from({length:c.sets},()=>({w:W, r:st.T, k:'work'}));
}
function warmupSets(c,planned){
  if(!c.warmups || !planned.length || planned.some(p=>p.w==null)) return [];
  const H=planned.reduce((m,p)=>asHard(c,p.w,m)?p.w:m, planned[0].w), first=planned[0].w, limit=down(c,first);
  return [[0.5,8],[0.7,4]].map(([f,r])=>({w:snapDown(c,H*f), r})).filter(x=>x.w>0 && x.w<=limit+EPS);
}

/* ---------- judging logged sets ---------- */
const working = sets => (sets||[]).filter(x=>x && !x.wu);
function judge(c, planned, logged){
  if(logged.length < planned.length) return {res:'incomplete', S:0, m:0};
  let S=0, m=0;
  planned.forEach((p,i)=>{
    const x=logged[i], r=+x.r||0, ok = p.w==null || asHard(c, +x.w||0, p.w);
    const s = ok ? Math.max(0, p.r-r) : Math.max(1, p.r-r);
    S+=s; m=Math.max(m,s);
  });
  return {res: S===0 ? 'met' : (m<=1 && S<=2) ? 'borderline' : 'missed', S, m};
}
/* Every set harder than planned by the same amount, every planned rep reached: that amount, else 0. */
function uniformShift(c, planned, logged){
  if(logged.length < planned.length || planned.some(p=>p.w==null)) return 0;
  const ds=planned.map((p,i)=>harderBy(c, +logged[i].w||0, p.w));
  const d=ds[0];
  if(!(d>EPS) || ds.some(x=>Math.abs(x-d)>EPS)) return 0;
  return planned.every((p,i)=>(+logged[i].r||0)>=p.r) ? d : 0;
}
const shiftW = (c,W,d) => assisted(c) ? W-d : W+d;
const clamp = (v,a,b) => Math.max(a, Math.min(b, v));

/* ---------- the rules per structure ---------- */
function startState(c){
  const st={v:1, s:c.structure, eq:c.eq, W:null, miss:0};
  if(c.structure==='pyramid') st.T=c.pattern[c.pattern.length-1];
  else if(c.structure==='topback'){ st.T=c.top[0]; st.Tb=c.back[0]; st.missB=0 }
  else st.T=c.lo;
  return st;
}
function bandOf(c){ return c.structure==='pyramid' ? [c.pattern[c.pattern.length-1], c.pattern[c.pattern.length-1]+2] : c.structure==='topback' ? c.top : [c.lo, c.hi] }
const isBW = (c,W) => !(W>0) && !assisted(c);

/* Missed-streak bookkeeping shared by every group of sets. Returns 'down' when the weight should step down. */
function missStep(res, miss){
  if(res==='incomplete') return {miss, act:'hold'};
  if(res==='borderline') return {miss:0, act:'hold'};
  if(res==='missed') return miss+1>=2 ? {miss:0, act:'down'} : {miss:miss+1, act:'hold'};
  return {miss:0, act:'up'};
}

function advanceMain(c, st, logged, hard){          // straight sets and pyramids
  const planned=st.planned, j=judge(c, planned, logged), [lo,hi]=bandOf(c), ns={...st}, ms=missStep(j.res, st.miss||0);
  ns.miss=ms.miss;
  let why;
  if(ms.act==='hold') why = j.res==='incomplete' ? 'Not every set was logged last time: same plan'
    : j.res==='borderline' ? 'Close to target last time: same plan' : 'Missed the target last time: same plan';
  else if(ms.act==='down'){ ns.W=easier(c,st.W); ns.T=lo; why='Missed twice in a row: one step lighter, reps reset' }
  else {
    const d=uniformShift(c, planned, logged);
    if(d){ ns.W=shiftW(c,st.W,d); why='You lifted heavier on every set: the plan moves up to match' }
    else if(c.structure==='straight' && isBW(c,st.W)){
      ns.T=Math.min(hi, st.T+c.repStep); why = ns.T===st.T ? 'Top of the range: hold it' : `+${c.repStep} ${c.timed?'sec':'rep'}`;
    } else {
      const top = c.structure==='straight' ? logged.slice(0,planned.length).every(x=>(+x.r||0)>=hi) : st.T>=hi;
      if(top && hard){ ns.T=hi; why='Rated Hard: same weight once more' }
      else if(top){ ns.W=harder(c,st.W); ns.T=lo; why = c.structure==='straight' ? `Every set hit ${hi}: weight up, reps back to ${lo}` : `Top set hit ${hi}: every set up a step` }
      else { ns.T=Math.min(hi, st.T+1); why = c.structure==='straight' ? 'Same weight, one more rep' : 'Top set: one more rep' }
    }
  }
  return {st:ns, why, result:j.res};
}

function advanceTopBack(c, st, logged, hard){
  const planned=st.planned, pTop=planned.slice(0,1), pBack=planned.slice(1);
  const jt=judge(c, pTop, logged.slice(0,1)), jb=judge(c, pBack, logged.slice(1));
  const ns={...st}, [a,b]=c.top, [cc,d]=c.back, why=[];
  const mt=missStep(jt.res, st.miss||0); ns.miss=mt.miss;
  if(mt.act==='down'){ ns.W=easier(c,st.W); ns.T=a; why.push('Top set missed twice: one step lighter') }
  else if(mt.act==='up'){
    const sh=uniformShift(c, pTop, logged.slice(0,1));
    if(sh){ ns.W=shiftW(c,st.W,sh); why.push('Top set heavier than planned: plan moves up to match') }
    else if(st.T>=b && hard){ why.push('Top set rated Hard: same weight once more') }
    else if(st.T>=b){ ns.W=harder(c,st.W); ns.T=a; why.push(`Top set hit ${b}: up a step`) }
    else { ns.T=Math.min(b, st.T+1); why.push('Top set: one more rep') }
  } else why.push('Top set: same plan');
  const mb=missStep(jb.res, st.missB||0); ns.missB=mb.miss;
  if(mb.act==='down'){ ns.Tb=cc; why.push('Back-offs missed twice: reps reset') }
  else if(mb.act==='up') ns.Tb=Math.min(d, st.Tb+1);
  if(backW(c,ns.W)!==backW(c,st.W)){ ns.Tb=cc; ns.missB=0 }      // new back-off weight: reps start at the bottom
  return {st:ns, why:why.join('. '), result:{top:jt.res, back:jb.res}};
}

/* First plan from a session logged without stored targets (older workouts), or after a structure change. */
function calibrate(c, logged, hold){
  const st=startState(c), sets=logged.filter(x=>x.r>0);
  if(!sets.length) return st;
  const inc = hold ? 0 : 1;
  const hardest = sets.reduce((m,x)=>asHard(c,+x.w||0,+m.w||0) && (+x.w||0)!==(+m.w||0) ? x : m, sets[0]);
  if(c.structure==='pyramid'){
    const pN=c.pattern[c.pattern.length-1], w=+hardest.w||0, e1=w*(1+hardest.r/30);
    st.W = Math.max(snapDown(c, e1/(1+pN/30)), up(c,0));
    return st;
  }
  if(c.structure==='topback'){
    const [a,b]=c.top, [cc,d]=c.back, w=+hardest.w||0, rest=sets.filter(x=>x!==hardest);
    if(!hold && hardest.r>=b){ st.W=harder(c,w); st.T=a; st.Tb=cc }
    else { st.W=w; st.T=clamp(hardest.r+inc, a, b); st.Tb = rest.length ? clamp(Math.min(...rest.map(x=>x.r))+inc, cc, d) : cc }
    return st;
  }
  // straight: the weight used for most sets (the harder one on a tie). If no weight was used for most sets (a ramp),
  // plan conservatively: loaded moves from the best set's estimated max at the bottom of the range with 2 reps to
  // spare; assisted moves from the middle assistance used.
  const count=new Map(); sets.forEach(x=>count.set(+x.w||0,(count.get(+x.w||0)||0)+1));
  let W=null, best=-1;
  [...count.entries()].forEach(([w,k])=>{ if(k>best || (k===best && asHard(c,w,W))){ W=w; best=k } });
  if(best*2<=sets.length && sets.length>1){
    if(assisted(c)){
      const ws=sets.map(x=>+x.w||0).sort((a,b)=>a-b);
      W=ws[Math.ceil((ws.length-1)/2)];
    } else if(!isBW(c,W)){
      const e1=Math.max(...sets.map(x=>(+x.w||0)*(1+x.r/30)));
      st.W=Math.max(snapDown(c, e1/(1+(c.lo+2)/30)), up(c,0)); st.T=c.lo;
      return st;
    }
  }
  const atW=sets.filter(x=>(+x.w||0)===W), minR=Math.min(...atW.map(x=>x.r));
  st.W=W;
  if(isBW(c,W)){ st.T=clamp(minR+(hold?0:c.repStep), c.lo, c.hi); return st }
  if(!hold && sets.length>=c.sets && atW.length===sets.length && minR>=c.hi){ st.W=harder(c,W); st.T=c.lo }
  else st.T=clamp(minR+inc, c.lo, c.hi);
  return st;
}

function resetReps(c, st){
  const [lo]=bandOf(c); st.T=lo; if(c.structure==='topback'){ st.Tb=c.back[0]; st.missB=0 } st.miss=0; return st;
}
const daysBetween = (a,b) => Math.round((Date.parse(b+'T12:00:00Z')-Date.parse(a+'T12:00:00Z'))/DAY);

/* The plan for one exercise.
   history: this exercise's earlier sessions, newest first: [{date, sets, prog?, diff?, deload?}].
   today: 'YYYY-MM-DD'. opts.deload: this is a deload week (about 60% weights; not judged later). */
function planFor(c, history, today, opts){
  const o=opts||{};
  let real=(history||[]).filter(h=>!h.deload && working(h.sets).some(x=>x.r>0));
  // A change of equipment starts the history fresh from that point.
  const cut=real.findIndex(h=>h.prog && h.prog.eq && h.prog.eq!==c.eq);
  if(cut>=0) real=real.slice(0,cut);
  let st, why, basedOn=null, result=null;
  if(!real.length){ st=startState(c); why='First time: pick a weight you could do for these reps with 1-2 to spare' }
  else {
    const last=real[0], logged=working(last.sets), gap=daysBetween(last.date, today);
    basedOn=last.date;
    const p=last.prog, usable = p && p.v===1 && p.s===c.structure && p.W!=null && Array.isArray(p.planned);
    if(gap>21){
      st = usable ? {...p} : calibrate(c, logged, true);
      if(gap<=42) why=`${gap} days since last time: same plan as before`;
      else if(gap<=84){ st.W=easier(c,st.W); resetReps(c,st); why=`${gap} days off: one step lighter to ease back in` }
      else { const w=snapEasy(c, assisted(c) ? st.W*1.1 : st.W*0.9); st.W = asHard(c,w,st.W) ? easier(c,st.W) : w; resetReps(c,st); why=`${gap} days off: about 10% lighter to ease back in` }
      st.miss=0; if(c.structure==='topback') st.missB=0;
    } else if(usable){
      const r = c.structure==='topback' ? advanceTopBack(c,p,logged,last.diff==='hard') : advanceMain(c,p,logged,last.diff==='hard');
      st=r.st; why=r.why; result=r.result;
    } else { st=calibrate(c, logged, false); why='Based on what you lifted last time' }
  }
  delete st.planned;
  const sets=plannedSets(c,st);
  st.planned=sets.map(x=>({w:x.w, r:x.r, k:x.k}));
  let shown=sets;
  if(o.deload && st.W!=null){
    shown=sets.map(x=>({...x, w: assisted(c) ? up(c,up(c,x.w)) : snapDown(c, x.w*0.6)}));
    why='Deload week: about 60% of your usual weight';
  }
  return {id:c.id, structure:c.structure, eq:c.eq, vf:c.vf, timed:c.timed,
    unit: assisted(c) ? 'lb assist' : c.vf===2 && c.eq!=='dumbbell' ? 'lb per arm' : c.eq==='dumbbell' ? 'lb per dumbbell' : 'lb',
    warmups: o.deload ? [] : warmupSets(c, shown), sets: shown, state: st, basedOn, why, last: result};
}

/* ---------- history, volume and helpers shared with the clients ---------- */
/* Sessions (web objects or Supabase rows {id,date,data}) to one exercise's history, newest first. */
function historyFor(sessions, exId, opts){
  const o=opts||{}, out=[];
  (sessions||[]).map(s=>s.data ? {...s.data, id:s.id, date:s.date} : s)
    .filter(s=>s.id!==o.excludeId && (!o.today || s.date<=o.today))
    .sort((a,b)=> a.date<b.date?1 : a.date>b.date?-1 : 0)
    .forEach(s=>{ const e=(s.entries||[]).find(x=>x.id===exId); if(e && e.sets && e.sets.length) out.push({date:s.date, sets:e.sets, prog:e.prog, diff:e.diff, deload:!!s.deload}) });
  return out;
}
/* A logged set with every field kept (actual w/r, original pw/pr, shown tw/tr, wu), numbers cleaned. */
function cleanSet(x){
  const o={...x, w:+x.w||0, r:+x.r||0};
  ['pw','pr','tw','tr'].forEach(k=>{ if(o[k]==null || o[k]==='') delete o[k]; else o[k]=+o[k] });
  if(!o.wu) delete o.wu;
  return o;
}
/* Weight moved by one working set: both dumbbells / both arms (vf), body weight minus assistance on assisted moves. */
function setVolume(c, x, bodyWeight){
  if(!x || x.wu) return 0;
  const w=+x.w||0, r=+x.r||0;
  if(assisted(c)) return bodyWeight ? Math.max(0, bodyWeight-w)*r : 0;
  return w*c.vf*r;
}
/* Plans for every exercise (and alternative) of every lift, for the Edge Function and the Watch cache. */
function buildPlans(input){
  const {sessions, settings, today, plan}=input, out={v:1, today, sessions:{}};
  Object.entries(plan.PLAN.sessions).forEach(([key,S])=>{
    if(S.type!=='lift') return;
    const ex={};
    S.ex.forEach(e=>{
      [e.id, ...(plan.ALTS[e.id]||[]).map(n=>plan.altId(e.id,n))].forEach(id=>{
        const c=configFor(plan.EXMAP[id], (settings||{})[id]);
        ex[id]=planFor(c, historyFor(sessions, id, {today}), today);
      });
    });
    out.sessions[key]=ex;
  });
  return out;
}

const P = {configFor, guessEquip, planFor, historyFor, buildPlans, cleanSet, setVolume, judge, working,
  snapDown, snapUp, up, down, harder, easier, asHard, isAssistName, isPerArmName, daysBetween};
if(typeof module!=='undefined' && module.exports) module.exports=P;
globalThis.Progression=P;
})();
