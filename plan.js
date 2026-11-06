/* Session's training plan, shared by the web app (index.html), the Supabase Edge Function that serves
   the Watch its targets, and watch/tools/gen-plan.mjs (which generates watch/Shared/Plan.swift).
   Each exercise: id, name, sets, reps [low, high], rest, eq (equipment: barbell | dumbbell | machine | cable |
   assisted | bodyweight), and optionally prog (its default set structure, see progression.js), small (2.5 lb steps
   on machines and cables), superset, timed (reps are seconds). Weights are per dumbbell and per arm.
   Alternatives get their equipment from their name and use straight sets unless changed in settings. */
/* ---------- Plan (mirrors the training plan doc) ---------- */
const PLAN = {
  week: {1:'upperA',2:'run',3:'lowerA',4:'upperB',5:'lowerB',6:'run',0:'rest'},
  sessions: {
    upperA:{name:'Upper A · heavy',type:'lift',ex:[
      {id:'bench',eq:'barbell',prog:{s:'pyramid',pattern:[10,8,6,5],gap:5},name:'Bench press',sets:4,reps:[5,8],rest:'2 min',note:'Main lift'},
      {id:'row',eq:'machine',name:'Chest-supported row',sets:4,reps:[6,10],rest:'90 sec'},
      {id:'ohp-db',eq:'dumbbell',name:'Seated dumbbell shoulder press',sets:3,reps:[8,10],rest:'75 sec'},
      {id:'pulldown',eq:'cable',name:'Lat pulldown',sets:3,reps:[8,12],rest:'75 sec'},
      {id:'pushdown',eq:'cable',name:'Triceps pushdown',sets:2,reps:[10,12],rest:'1 min',small:1},
      {id:'db-curl',eq:'dumbbell',name:'Dumbbell curl',sets:2,reps:[10,12],rest:'1 min',small:1}]},
    lowerA:{name:'Lower A · squat',type:'lift',ex:[
      {id:'squat',eq:'barbell',prog:{s:'pyramid',pattern:[10,8,6,5],gap:10},name:'Back squat',sets:4,reps:[5,8],rest:'2 min',note:'Main lift'},
      {id:'rdl',eq:'barbell',name:'Romanian deadlift',sets:3,reps:[8,10],rest:'90 sec'},
      {id:'lunge',eq:'dumbbell',name:'Bulgarian split squat (per leg)',sets:3,reps:[8,10],rest:'75 sec'},
      {id:'leg-curl',eq:'machine',name:'Leg curl',sets:3,reps:[10,12],rest:'1 min',small:1},
      {id:'calf-st',eq:'machine',name:'Standing calf raise',sets:4,reps:[10,15],rest:'1 min',small:1}]},
    upperB:{name:'Upper B · volume',type:'lift',ex:[
      {id:'inc-db',eq:'dumbbell',prog:{s:'pyramid',pattern:[12,10,8,6],gap:5},name:'Incline dumbbell press',sets:4,reps:[8,12],rest:'90 sec',note:'Main lift'},
      {id:'cable-row',eq:'cable',name:'Seated cable row',sets:4,reps:[8,12],rest:'75 sec'},
      {id:'ohp',eq:'barbell',prog:{s:'pyramid',pattern:[10,8,6],gap:5},name:'Barbell overhead press',sets:3,reps:[6,10],rest:'90 sec'},
      {id:'pullup',eq:'assisted',name:'Pull-ups',sets:3,reps:[6,12],rest:'90 sec',note:'As many clean reps as you can each set, stopping 1-2 short of failure'},
      {id:'fly',eq:'cable',name:'Single-arm cable fly',sets:3,reps:[12,15],rest:'1 min',small:1},
      {id:'rear',eq:'cable',name:'Single-arm rear delt fly',sets:3,reps:[15,15],rest:'1 min',small:1},
      {id:'ss-curl',eq:'barbell',name:'EZ-bar curl',sets:3,reps:[10,12],rest:'1 min',small:1,superset:'arms'},
      {id:'ss-tri',eq:'cable',name:'Overhead triceps extension',sets:3,reps:[10,12],rest:'1 min',small:1,superset:'arms'}]},
    lowerB:{name:'Lower B · hinge + core',type:'lift',ex:[
      {id:'deadlift',eq:'barbell',prog:{s:'topback',top:[4,6],back:[6,8],backSets:2,pct:0.85},name:'Deadlift',sets:3,reps:[4,6],rest:'2 min',note:'Main lift. Keep 1-2 reps in reserve'},
      {id:'front-sq',eq:'barbell',name:'Front squat',sets:3,reps:[8,10],rest:'90 sec'},
      {id:'hip-thrust',eq:'barbell',name:'Hip thrust',sets:3,reps:[8,12],rest:'75 sec'},
      {id:'leg-ext',eq:'machine',name:'Leg extension',sets:3,reps:[12,15],rest:'1 min',small:1},
      {id:'calf-seat',eq:'machine',name:'Seated calf raise',sets:3,reps:[12,15],rest:'1 min',small:1},
      {id:'knee-raise',eq:'bodyweight',name:'Hanging knee raise',sets:3,reps:[10,15],rest:'1 min'},
      {id:'plank',eq:'bodyweight',timed:1,name:'Plank (seconds in the reps box)',sets:3,reps:[45,60],rest:'50 sec'}]},
    run:{name:'Run',type:'run',note:'Weeks 1-2: 20-25 min easy. Weeks 3-4: 30 min. Weeks 5-8: build to 40-45 min, add a weekly interval session (6 x 2 min hard / 2 min easy).'},
    yoga:{name:'Hot yoga',type:'yoga',note:'Log the class length. How it felt goes on the next screen.'},
    rest:{name:'Rest day',type:'rest'}
  }
};

/* alternatives per exercise: each alternative keeps its own history so weights stay comparable */
const slug = s => s.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'');
const altId = (slot,name) => slot+'~'+slug(name);
const ALTS = {
  bench:['Dumbbell bench press','Machine chest press','Smith machine bench'],
  row:['Barbell row','Seated cable row','T-bar row','One-arm dumbbell row'],
  'ohp-db':['Machine shoulder press','Arnold press','Barbell overhead press'],
  pulldown:['Pull-ups','Assisted pull-ups','Close-grip pulldown'],
  pushdown:['Seated triceps press machine','Rope pushdown','Overhead triceps extension','Dips'],
  'db-curl':['EZ-bar curl','Cable curl','Hammer curl'],
  squat:['Leg press','Hack squat','Goblet squat','Smith machine squat'],
  rdl:['Dumbbell RDL','Good morning','Back extension'],
  lunge:['Walking lunge','Step-up','Reverse lunge'],
  'leg-curl':['Seated leg curl','Lying leg curl','Nordic curl'],
  'calf-st':['Leg press calf raise','Smith calf raise'],
  'inc-db':['Incline barbell press','Incline machine press','Dumbbell bench press'],
  'cable-row':['Chest-supported row','Machine row','Barbell row'],
  ohp:['Machine shoulder press','Seated dumbbell press','Landmine press'],
  pullup:['Assisted pull-ups','Lat pulldown','Chin-ups'],
  fly:['Pec deck','Dumbbell fly','Cable crossover'],
  rear:['Face pull','Reverse pec deck','Rear delt cable fly'],
  'ss-curl':['Dumbbell curl','Cable curl','Preacher curl'],
  'ss-tri':['Seated triceps press machine','Triceps pushdown','Skull crushers','Dips'],
  deadlift:['Trap-bar deadlift','Rack pull','Sumo deadlift'],
  'front-sq':['Hack squat','Leg press','Goblet squat'],
  'hip-thrust':['Glute bridge','Cable pull-through','Back extension'],
  'leg-ext':['Sissy squat','Single-leg extension'],
  'calf-seat':['Standing calf raise','Leg press calf raise'],
  'knee-raise':['Cable crunch','Ab wheel','Decline sit-up'],
  plank:['Side plank','Dead bug','Hollow hold']
};
/* Exercises that only appear in program templates (programs.js), not in the original four workouts. */
const EXTRA = [
  {id:'lat-raise',eq:'dumbbell',name:'Lateral raise',sets:3,reps:[12,15],rest:'1 min',small:1}
];
ALTS['lat-raise'] = ['Cable lateral raise','Machine lateral raise'];
/* Muscles each exercise trains, for weekly volume (programs.js): 1 = a main muscle, 0.5 = a supporting one.
   One working set of bench press counts 1 chest + 0.5 triceps + 0.5 shoulders. Alternatives count as the
   exercise they replace. Muscles: chest back shoulders triceps biceps quads glutes hamstrings calves core. */
const MUSCLES = {
  bench:{chest:1,triceps:.5,shoulders:.5}, 'inc-db':{chest:1,shoulders:.5,triceps:.5}, fly:{chest:1},
  ohp:{shoulders:1,triceps:.5}, 'ohp-db':{shoulders:1,triceps:.5}, 'lat-raise':{shoulders:1}, rear:{shoulders:1},
  row:{back:1,biceps:.5}, 'cable-row':{back:1,biceps:.5}, pulldown:{back:1,biceps:.5}, pullup:{back:1,biceps:.5},
  pushdown:{triceps:1}, 'ss-tri':{triceps:1}, 'db-curl':{biceps:1}, 'ss-curl':{biceps:1},
  squat:{quads:1,glutes:.5}, 'front-sq':{quads:1,glutes:.5}, lunge:{quads:1,glutes:.5}, 'leg-ext':{quads:1},
  rdl:{hamstrings:1,glutes:.5}, 'leg-curl':{hamstrings:1}, deadlift:{hamstrings:1,glutes:1,back:.5},
  'hip-thrust':{glutes:1,hamstrings:.5}, 'calf-st':{calves:1}, 'calf-seat':{calves:1},
  'knee-raise':{core:1}, plank:{core:1}
};
const EXMAP = {};
[...Object.values(PLAN.sessions), {ex:EXTRA}].forEach(S=>(S.ex||[]).forEach(e=>{
  EXMAP[e.id]={...e,slot:e.id};
  (ALTS[e.id]||[]).forEach(n=>{ const id=altId(e.id,n); EXMAP[id]={...e,id,name:n,slot:e.id,note:undefined,alt:true,eq:undefined,prog:undefined,timed:e.timed&&/plank|hold/i.test(n)?1:undefined} });
}));

if(typeof module!=='undefined' && module.exports) module.exports={PLAN,ALTS,slug,altId,EXMAP,MUSCLES,EXTRA};
globalThis.WorkoutPlan={PLAN,ALTS,slug,altId,EXMAP,MUSCLES,EXTRA};
