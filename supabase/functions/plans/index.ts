// Edge Function "plans": the Watch's source of targets and schedule. It runs the same plan.js, progression.js and
// programs.js as the web app (copied next to this file at deploy time from the repo root, which stays the only
// source) over the signed-in user's own data, and returns full plans for every workout, the training program,
// its workouts and this week's and next week's scheduled workouts. The Watch caches the response, so it keeps
// working offline. Reads only, with the caller's own login (row-level security applies).
//
// GET  /functions/v1/plans?today=YYYY-MM-DD   (today = the Watch's local date; defaults to UTC today)
// POST /functions/v1/plans {sessions, settings, today, prog?, changes?}: the same computation over the posted
//      data, touching no stored data. Used by tools/check-plans-function.mjs to confirm the deployed copy matches.
import './plan.js';
import './progression.js';
import './programs.js';

const { Progression, Programs } = globalThis as any;
const json = (o: unknown) => new Response(JSON.stringify(o), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

Deno.serve(async (req) => {
  const auth = req.headers.get('Authorization');
  if (!auth) return new Response('Sign in required', { status: 401 });
  if (req.method === 'POST') {
    const text = await req.text();
    if (text.length > 1_000_000) return new Response('Too large', { status: 413 });
    const b = JSON.parse(text || '{}');
    const today = /^\d{4}-\d{2}-\d{2}$/.test(b.today) ? b.today : '2026-01-01';
    return json(Programs.watchPayload(Progression, { sessions: Array.isArray(b.sessions) ? b.sessions : [], settings: b.settings || {}, today,
      prog: b.prog || null, changes: Array.isArray(b.changes) ? b.changes : [] }));
  }
  const url = Deno.env.get('SUPABASE_URL')!, key = Deno.env.get('SUPABASE_ANON_KEY')!;
  const q = new URL(req.url).searchParams.get('today') || '';
  const today = /^\d{4}-\d{2}-\d{2}$/.test(q) ? q : new Date().toISOString().slice(0, 10);
  const headers = { apikey: key, Authorization: auth };
  const day = (n: number) => new Date(Date.parse(today + 'T12:00:00Z') + n * 864e5).toISOString().slice(0, 10);
  const [sr, er, pr, cr] = await Promise.all([
    fetch(`${url}/rest/v1/sessions?select=id,date,session,type,data&status=eq.complete&date=gte.${day(-400)}&order=date.desc`, { headers }),
    fetch(`${url}/rest/v1/exercise_settings?select=exercise_id,structure,equipment,step`, { headers }),
    fetch(`${url}/rest/v1/programs?select=config,past`, { headers }),
    fetch(`${url}/rest/v1/schedule_changes?select=id,change&week=gte.${day(-180)}`, { headers }),
  ]);
  if (!sr.ok) return new Response(await sr.text(), { status: sr.status });
  const sessions = await sr.json();
  const settings: Record<string, unknown> = {};
  if (er.ok) for (const x of await er.json()) {
    settings[x.exercise_id] = { structure: x.structure ?? undefined, equipment: x.equipment ?? undefined, step: x.step ?? undefined };
  }
  // Before the programs tables exist (or with no saved program), this is the original plan.
  const progRow = pr.ok ? (await pr.json())[0] : null;
  const changes = cr.ok ? await cr.json() : [];
  const out = Programs.watchPayload(Progression, { sessions, settings, today, prog: progRow ? { config: progRow.config, past: progRow.past || [] } : null, changes });
  out.generatedAt = new Date().toISOString();
  return json(out);
});
