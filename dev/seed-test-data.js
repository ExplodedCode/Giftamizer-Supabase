#!/usr/bin/env node
//
// Populates a running local dev stack with sample data: 5 users, 2 groups,
// and 30 items, exercising the real auth.users -> profiles -> lists signup
// flow (same spirit as dev/data.sql's comment about signing up through the
// app instead of hand-inserting rows) rather than inserting rows directly.
//
// Requires the stack to already be up (./run.sh dev up / .\run.ps1 dev up)
// and a fresh database, since it creates fixed test-user emails that will
// collide with a previous run - reset first if you need to re-seed:
//   ./reset.sh && ./run.sh dev up          (or the .ps1 equivalents)
//
// Usage:
//   node dev/seed-test-data.js
//
// No dependencies beyond Node's built-ins (fetch, crypto) - run with Node 18+.

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.resolve(__dirname, '..');

function loadEnvFile(file) {
  const out = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }
    out[key] = value;
  }
  return out;
}

const env = { ...loadEnvFile(path.join(ROOT, '.env.example')), ...loadEnvFile(path.join(ROOT, '.env')) };

const API_URL = (env.API_EXTERNAL_URL || 'http://localhost:8000').replace(/\/$/, '');
const ANON_KEY = env.ANON_KEY;
const SERVICE_ROLE_KEY = env.SERVICE_ROLE_KEY;
const JWT_SECRET = env.JWT_SECRET;

if (!ANON_KEY || !SERVICE_ROLE_KEY || !JWT_SECRET) {
  console.error('Missing ANON_KEY / SERVICE_ROLE_KEY / JWT_SECRET - run this from a checkout with a configured .env (see .env.example).');
  process.exitCode = 1;
  return;
}

const PASSWORD = 'Password123!';

const USERS = [
  {
    first_name: 'Alice', last_name: 'Anderson', email: 'alice@giftamizer.test', bio: 'Coffee enthusiast, always cold, easy to shop for.', enable_lists: true,
    extraLists: [{ name: 'Birthday Wishlist', child_list: false }],
  },
  {
    first_name: 'Ben', last_name: 'Baker', email: 'ben@giftamizer.test', bio: 'Board game collector and mediocre chef.', enable_lists: true,
    extraLists: [
      { name: 'Holiday Wishlist', child_list: false },
      { name: 'Just Because', child_list: false },
    ],
  },
  {
    first_name: 'Carla', last_name: 'Chen', email: 'carla@giftamizer.test', bio: 'Professional plant parent.', enable_lists: true,
    // Child lists: Carla manages wishlists on behalf of her kids from her own account.
    extraLists: [
      { name: "Jack's List", child_list: true },
      { name: "Lily's List", child_list: true },
    ],
  },
  { first_name: 'Diego', last_name: 'Diaz', email: 'diego@giftamizer.test', bio: 'Runs on caffeine and spreadsheets.', enable_lists: false, extraLists: [] },
  { first_name: 'Erin', last_name: 'Evans', email: 'erin@giftamizer.test', bio: 'Books, hikes, and too many houseplants.', enable_lists: false, extraLists: [] },
];

const ITEM_NAMES = [
  'Wireless Headphones', 'Yeti Tumbler', 'Catan Board Game', 'Espresso Machine', 'Hiking Boots',
  'Kindle Paperwhite', 'Instant Pot', 'Leather Wallet', 'Bluetooth Speaker', 'Cast Iron Skillet',
  '1000-Piece Puzzle', 'Scented Candle Set', 'Running Shoes', 'Graphic Novel Box Set', 'Smartwatch',
  'Manual Coffee Grinder', 'Yoga Mat', 'Desk Succulent', 'Air Fryer', 'Noise Cancelling Earbuds',
  'Vinyl Record Player', 'Baking Basics Cookbook', 'Weighted Blanket', 'Portable Charger', 'Mechanical Keyboard',
  'Insulated Water Bottle', 'Photo Album', 'Ticket to Ride Board Game', 'Wireless Mouse', 'Chunky Throw Blanket',
];

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function signJwt(payload) {
  const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = base64url(JSON.stringify(payload));
  const data = `${header}.${body}`;
  const sig = crypto.createHmac('sha256', JWT_SECRET).update(data).digest('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  return `${data}.${sig}`;
}

// Mints a short-lived access token for a given user, the same way GoTrue
// would - so REST/Storage requests hit the exact same RLS policies (and
// owner-assigning triggers that key off auth.uid()) a real logged-in session
// would, instead of bypassing them with the service role key.
function userJwt(userId, email) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({ role: 'authenticated', aud: 'authenticated', sub: userId, email, iss: 'supabase', iat: now, exp: now + 3600 });
}

async function waitForStack(timeoutMs = 60000) {
  const start = Date.now();
  for (;;) {
    try {
      await fetch(`${API_URL}/rest/v1/`, { headers: { apikey: ANON_KEY } });
      return;
    } catch (err) {
      if (Date.now() - start > timeoutMs) {
        throw new Error(`Could not reach ${API_URL} - is the stack up? Try "./run.sh dev up" (".\\run.ps1 dev up" on Windows), wait for it to become healthy, then re-run this script.`);
      }
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
}

async function rest(method, pathAndQuery, { jwt, body, prefer } = {}) {
  const headers = { apikey: ANON_KEY, Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' };
  if (prefer) headers.Prefer = prefer;
  const res = await fetch(`${API_URL}/rest/v1/${pathAndQuery}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`${method} /rest/v1/${pathAndQuery} -> ${res.status} ${text}`);
  }
  return text ? JSON.parse(text) : null;
}

async function createAuthUser({ email, first_name, last_name }) {
  const res = await fetch(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: { apikey: SERVICE_ROLE_KEY, Authorization: `Bearer ${SERVICE_ROLE_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: PASSWORD, email_confirm: true, user_metadata: { first_name, last_name } }),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(
      `Creating user ${email} failed (${res.status}): ${JSON.stringify(data)}\n` +
      `If this is a re-run, reset the dev database first: ./reset.sh (or .\\reset.ps1), then ./run.sh dev up.`
    );
  }
  return data;
}

async function withRetry(fn, attempts = 3, delayMs = 1500) {
  let lastErr;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (i < attempts - 1) await new Promise((r) => setTimeout(r, delayMs));
    }
  }
  throw lastErr;
}

async function uploadImage(bucket, objectName, jwt, seed, { width = 600, height = 600 } = {}) {
  const imgRes = await fetch(`https://picsum.photos/seed/${encodeURIComponent(seed)}/${width}/${height}`);
  if (!imgRes.ok) throw new Error(`picsum fetch failed for seed "${seed}": ${imgRes.status}`);
  const buffer = Buffer.from(await imgRes.arrayBuffer());
  const contentType = imgRes.headers.get('content-type') || 'image/jpeg';

  const res = await fetch(`${API_URL}/storage/v1/object/${bucket}/${objectName}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': contentType, 'x-upsert': 'true' },
    body: buffer,
  });
  if (!res.ok) {
    throw new Error(`Uploading to ${bucket}/${objectName} failed (${res.status}): ${await res.text()}`);
  }
}

// Fetches + uploads a picsum image for one entity, then bumps its *_token
// column so the frontend's cache-busted image URL picks up the new file.
async function seedImage({ bucket, objectName, jwt, seed, width, height, patchQuery, tokenField }) {
  await withRetry(async () => {
    await uploadImage(bucket, objectName, jwt, seed, { width, height });
    await rest('PATCH', patchQuery, { jwt, body: { [tokenField]: Date.now() } });
  });
}

function shuffle(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function pickSubset(arr, pct) {
  return shuffle(arr).slice(0, Math.round(arr.length * pct));
}

function descriptionFor(name) {
  return `Saw this and thought of it for the list - ${name.toLowerCase()}.`;
}

async function main() {
  console.log(`Seeding test data via ${API_URL} ...`);
  await waitForStack();

  console.log('Creating users...');
  const users = [];
  for (const u of USERS) {
    const authUser = await createAuthUser(u);
    const jwt = userJwt(authUser.id, u.email);
    users.push({ ...u, id: authUser.id, jwt });
    console.log(`  ${u.email} (${authUser.id})`);
  }

  console.log('Updating profiles (bio, enable_lists)...');
  for (const u of users) {
    await rest('PATCH', `profiles?user_id=eq.${u.id}`, { jwt: u.jwt, body: { bio: u.bio, enable_lists: u.enable_lists } });
  }

  console.log('Creating groups...');
  const groupDefs = [
    { name: 'Family Gift Exchange', owner: users[0] },
    { name: 'Office Secret Santa', owner: users[1] },
  ];
  const groups = [];
  for (const g of groupDefs) {
    const [row] = await rest('POST', 'groups', { jwt: g.owner.jwt, body: { name: g.name }, prefer: 'return=representation' });
    groups.push({ id: row.id, name: g.name, owner: g.owner });
    console.log(`  ${g.name} (${row.id}), owner ${g.owner.email}`);
  }

  console.log('Adding group members...');
  for (const group of groups) {
    for (const u of users) {
      if (u.id === group.owner.id) continue;
      await rest('POST', 'group_members', { jwt: group.owner.jwt, body: { group_id: group.id, user_id: u.id, invite: false } });
    }
  }

  console.log('Creating extra lists...');
  // Every user already has the 'default' list created by the handle_new_user
  // trigger on signup - only create the additional ones called for here.
  const lists = [];
  for (const u of users) {
    lists.push({ id: 'default', user: u, name: 'Default', isDefault: true });
    for (const { name, child_list } of u.extraLists) {
      const [row] = await rest('POST', 'lists', { jwt: u.jwt, body: { name, user_id: u.id, child_list }, prefer: 'return=representation' });
      lists.push({ id: row.id, user: u, name, isDefault: false });
      console.log(`  ${u.email}: "${name}"${child_list ? ' (child list)' : ''} (${row.id})`);
    }
  }

  console.log('Publishing extra lists to both groups (so they show up separately in group lists)...');
  for (const l of lists.filter((l) => !l.isDefault)) {
    for (const group of groups) {
      await rest('POST', 'lists_groups', { jwt: l.user.jwt, body: { list_id: l.id, group_id: group.id, user_id: l.user.id } });
    }
  }

  console.log('Creating items...');
  const items = [];
  let nameIdx = 0;
  for (const u of users) {
    const userLists = lists.filter((l) => l.user.id === u.id);
    for (let i = 0; i < 6; i++) {
      const name = ITEM_NAMES[nameIdx++ % ITEM_NAMES.length];
      const [row] = await rest('POST', 'items', {
        jwt: u.jwt,
        body: { name, description: descriptionFor(name), user_id: u.id },
        prefer: 'return=representation',
      });
      items.push({ id: row.id, user: u });

      if (u.enable_lists) {
        const targetList = userLists[i % userLists.length];
        await rest('POST', 'items_lists', { jwt: u.jwt, body: { item_id: row.id, list_id: targetList.id, user_id: u.id } });
      }
    }
  }
  console.log(`  ${items.length} items created`);

  console.log('Uploading avatar images (~70% of users)...');
  for (const u of pickSubset(users, 0.7)) {
    await seedImage({
      bucket: 'avatars', objectName: u.id, jwt: u.jwt, seed: `avatar-${u.id}`, width: 400, height: 400,
      patchQuery: `profiles?user_id=eq.${u.id}`, tokenField: 'avatar_token',
    });
  }

  console.log('Uploading group images (~70% of groups)...');
  for (const g of pickSubset(groups, 0.7)) {
    await seedImage({
      bucket: 'groups', objectName: g.id, jwt: g.owner.jwt, seed: `group-${g.id}`, width: 1200, height: 400,
      patchQuery: `groups?id=eq.${g.id}`, tokenField: 'image_token',
    });
  }

  console.log('Uploading list images (~70% of non-default lists)...');
  // The lists storage bucket's RLS policy (is_list_owner in 0005-items.sql)
  // keys objects by the bare list id, and every user's auto-created list
  // uses the literal id 'default' - so a 'default' object would collide
  // across every user. Only the extra, uniquely-id'd lists get images.
  for (const l of pickSubset(lists.filter((l) => !l.isDefault), 0.7)) {
    await seedImage({
      bucket: 'lists', objectName: l.id, jwt: l.user.jwt, seed: `list-${l.user.id}-${l.id}`, width: 400, height: 400,
      patchQuery: `lists?id=eq.${l.id}&user_id=eq.${l.user.id}`, tokenField: 'avatar_token',
    });
  }

  console.log('Uploading item images (~70% of items)...');
  for (const it of pickSubset(items, 0.7)) {
    await seedImage({
      bucket: 'items', objectName: it.id, jwt: it.user.jwt, seed: `item-${it.id}`, width: 600, height: 600,
      patchQuery: `items?id=eq.${it.id}`, tokenField: 'image_token',
    });
  }

  console.log('\nDone. Seeded users (password for all: ' + PASSWORD + '):');
  for (const u of users) console.log(`  ${u.email}${u.enable_lists ? ' (lists enabled)' : ''}`);
}

main().catch((err) => {
  console.error('\nSeed failed:', err.message);
  // Not process.exit(1): that forces handles closed immediately and races
  // with fetch's keep-alive sockets, which crashes Node on Windows (libuv
  // assertion in src/win/async.c). Setting exitCode lets the event loop
  // drain naturally while still failing the process.
  process.exitCode = 1;
});
