// The board's email outbox, for the Claude task that sends the emails (docs/SETUP.md, step 8).
//
//   node mailer/outbox.mjs take                  prints the emails waiting, as JSON, and marks them taken
//   node mailer/outbox.mjs done <id>             after an email went out
//   node mailer/outbox.mjs fail <id> "<why>"     if it could not be sent
//
// The project URL and publishable key come from site/config.js. The Claude key (Team > Email > Copy key)
// goes in mailer/claude-key.txt, which is never committed, or in the NUDGE_CLAUDE_KEY environment variable.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const die = (msg) => { console.error(msg); process.exit(1); };

const config = fs.readFileSync(path.join(here, '..', 'site', 'config.js'), 'utf8');
const pick = (name) => (config.match(new RegExp(name + "\\s*:\\s*'([^']*)'")) || [])[1] || '';
const url = pick('supabaseUrl'), apikey = pick('supabaseKey');
if (!url || !apikey) die('site/config.js has no supabaseUrl or supabaseKey yet.');

let key = process.env.NUDGE_CLAUDE_KEY || '';
const keyFile = path.join(here, 'claude-key.txt');
if (!key && fs.existsSync(keyFile)) key = fs.readFileSync(keyFile, 'utf8').trim();
if (!key) die('No Claude key. Copy it from the board (Team > Email > Copy key) into mailer/claude-key.txt.');

async function rpc(name, body) {
  const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: { apikey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ p_key: key, ...body }),
  });
  const text = await res.text();
  if (!res.ok) die(`The board said no (${res.status}): ${text}`);
  return JSON.parse(text);
}

const [cmd, id, ...why] = process.argv.slice(2);
if (cmd === 'take') {
  console.log(JSON.stringify(await rpc('claude_outbox_take', { p_limit: 20 }), null, 2));
} else if ((cmd === 'done' || cmd === 'fail') && id) {
  const ok = cmd === 'done';
  const changed = await rpc('claude_outbox_done', { p_id: id, p_ok: ok, p_detail: ok ? null : why.join(' ') || null });
  console.log(changed ? 'Recorded.' : 'Nothing changed: that email was not waiting (already recorded, or too old).');
} else {
  die('Usage: node mailer/outbox.mjs take | done <id> | fail <id> "<why>"');
}
