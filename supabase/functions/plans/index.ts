// Edge Function "plans": the Watch's source of targets. It runs the same progression.js and plan.js as the
// web app (copied next to this file at deploy time from the repo root, which stays the only source) over the
// signed-in user's own workouts, and returns full plans for every lift. The Watch caches the response, so it
// keeps working offline. Reads only, with the caller's own login (row-level security applies).
//
// GET  /functions/v1/plans?today=YYYY-MM-DD   (today = the Watch's local date; defaults to UTC today)
// POST /functions/v1/plans {sessions, settings, today}: the same computation over the posted history, touching no
//      stored data. Used by tools/check-plans-function.mjs to confirm the deployed copy matches the repo.
import './plan.js';
import './progression.js';

const { WorkoutPlan, Progression } = globalThis as any;

Deno.serve(async (req) => {
  const auth = req.headers.get('Authorization');
  if (!auth) return new Response('Sign in required', { status: 401 });
  if (req.method === 'POST') {
    const text = await req.text();
    if (text.length > 1_000_000) return new Response('Too large', { status: 413 });
    const b = JSON.parse(text || '{}');
    const t = /^\d{4}-\d{2}-\d{2}$/.test(b.today) ? b.today : '2026-01-01';
    const out = Progression.buildPlans({ sessions: Array.isArray(b.sessions) ? b.sessions : [], settings: b.settings || {}, today: t, plan: WorkoutPlan });
    return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
  }
  const url = Deno.env.get('SUPABASE_URL')!, key = Deno.env.get('SUPABASE_ANON_KEY')!;
  const q = new URL(req.url).searchParams.get('today') || '';
  const today = /^\d{4}-\d{2}-\d{2}$/.test(q) ? q : new Date().toISOString().slice(0, 10);
  const headers = { apikey: key, Authorization: auth };
  const since = new Date(Date.parse(today + 'T12:00:00Z') - 400 * 864e5).toISOString().slice(0, 10);
  const [sr, er] = await Promise.all([
    fetch(`${url}/rest/v1/sessions?select=id,date,data&status=eq.complete&type=eq.lift&date=gte.${since}&order=date.desc`, { headers }),
    fetch(`${url}/rest/v1/exercise_settings?select=exercise_id,structure,equipment,step`, { headers }),
  ]);
  if (!sr.ok) return new Response(await sr.text(), { status: sr.status });
  const sessions = await sr.json();
  const settings: Record<string, unknown> = {};
  if (er.ok) for (const x of await er.json()) {
    settings[x.exercise_id] = { structure: x.structure ?? undefined, equipment: x.equipment ?? undefined, step: x.step ?? undefined };
  }
  const out = Progression.buildPlans({ sessions, settings, today, plan: WorkoutPlan });
  out.generatedAt = new Date().toISOString();
  return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
});
