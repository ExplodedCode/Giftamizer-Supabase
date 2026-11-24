#!/usr/bin/env node
//
// Populates a running local dev stack with sample data: 5 users, 2 groups,
// and their wishlists, exercising the real auth.users -> profiles -> lists
// signup flow (same spirit as dev/data.sql's comment about signing up through
// the app instead of hand-inserting rows) rather than inserting rows directly.
//
// The data itself (people, real products, descriptions) is in dev/seed-data.js
// and the photos are in dev/seed-images - this file only has the logic, and
// needs no network access beyond the local stack.
//
// It also seeds the Feed (0016-activity-feed.sql). The feed is filled by
// database triggers, so this script does NOT insert activity rows - it performs
// real actions as different users (edit an item, claim then archive it, leave
// and rejoin a group, draw Secret Santa, ...) and lets the triggers log them.
// Afterwards it back-dates those rows (service role) so the feed reads like
// two weeks of history instead of one burst, and sets each user's
// feed_seen_at so some have unread badges. Log in as any seeded user to see
// the others' activity - a user never sees their own events.
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

const { USERS, GROUPS, FEED } = require('./seed-data.js');

const IMAGES_DIR = path.join(__dirname, 'seed-images');
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

async function uploadImage(bucket, objectName, jwt, file) {
  const buffer = fs.readFileSync(path.join(IMAGES_DIR, file));
  const res = await fetch(`${API_URL}/storage/v1/object/${bucket}/${objectName}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'image/jpeg', 'x-upsert': 'true' },
    body: buffer,
  });
  if (!res.ok) {
    throw new Error(`Uploading ${file} to ${bucket}/${objectName} failed (${res.status}): ${await res.text()}`);
  }
}

// Uploads an image for one entity, then bumps its *_token column so the
// frontend's cache-busted image URL picks up the new file.
async function seedImage({ bucket, objectName, jwt, file, patchQuery, tokenField }) {
  await withRetry(async () => {
    await uploadImage(bucket, objectName, jwt, file);
    await rest('PATCH', patchQuery, { jwt, body: { [tokenField]: Date.now() } });
  });
}

// Items don't use a *_token column - each image is its own item_images row,
// stored at items/{itemId}/{imageId} (see 0014-item-multi-images.sql).
async function seedItemImage({ item, position, file }) {
  const imageId = crypto.randomUUID();
  await withRetry(async () => {
    await uploadImage('items', `${item.id}/${imageId}`, item.user.jwt, file);
    await rest('POST', 'item_images', { jwt: item.user.jwt, body: { id: imageId, item_id: item.id, user_id: item.user.id, position } });
  });
}

async function seedItemImages(item, files = []) {
  for (let position = 0; position < files.length; position++) {
    await seedItemImage({ item, position, file: files[position] });
  }
}

// { Size: 'M' } -> [{ id: 0, name: 'Size', value: 'M' }], the shape the app stores.
function customFields(fields = {}) {
  return Object.entries(fields).map(([name, value], id) => ({ id, name, value }));
}

// Creates one item (an entry of USERS[].items) and puts it on its list, if any.
async function createItem(user, def, lists) {
  const [row] = await rest('POST', 'items', {
    jwt: user.jwt,
    body: { name: def.name, description: def.description, links: def.links ?? [], custom_fields: customFields(def.fields), user_id: user.id },
    prefer: 'return=representation',
  });
  if (def.list) {
    const list = lists.find((l) => l.user.id === user.id && l.name === def.list);
    if (!list) throw new Error(`Item "${def.key}" is on list "${def.list}", which ${user.email} doesn't have`);
    await rest('POST', 'items_lists', { jwt: user.jwt, body: { item_id: row.id, list_id: list.id, user_id: user.id } });
  }
  return { id: row.id, key: def.key, user, images: def.images };
}

function shuffle(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

// ---------------------------------------------------------------------------
// Feed seeding
// ---------------------------------------------------------------------------
const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

// Same shape as moment's 'LL', which is how the app stores the Secret Santa date.
function formatLongDate(date) {
  return date.toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
}

// public.activity is only readable/writable by the service role (clients go
// through get_feed()), so these helpers use the service role key.
async function allActivity() {
  return rest('GET', 'activity?select=id,type&order=created_at.asc,id.asc', { jwt: SERVICE_ROLE_KEY });
}

async function setActivityTime(id, whenMs) {
  await rest('PATCH', `activity?id=eq.${id}`, { jwt: SERVICE_ROLE_KEY, body: { created_at: new Date(whenMs).toISOString() } });
}

// Runs one scenario step as real user actions, then moves every activity row
// the step caused to `agoMs` ago. Steps must run oldest -> newest: the
// triggers' "just created" (10 min) and merge (30 min) windows use the real
// clock, so each step has to be moved into the past before the next one runs.
async function feedStep(label, agoMs, fn) {
  console.log(`  ${label}`);
  const before = new Set((await allActivity()).map((r) => r.id));
  await fn();
  const fresh = (await allActivity()).filter((r) => !before.has(r.id));
  const start = Date.now() - agoMs;
  for (let i = 0; i < fresh.length; i++) await setActivityTime(fresh[i].id, start + i * 45 * 1000);
}

// Everything the base seed did happened within a few seconds. Drop the
// setup-only noise (bios, avatars and group photos set while creating the
// accounts) and spread the rest - joins, list shares, item adds - over days
// 14..7 ago, keeping their original order.
async function spreadSetupActivity() {
  await rest('DELETE', 'activity?type=in.(profile_updated,group_updated)', { jwt: SERVICE_ROLE_KEY });
  const rows = await allActivity();
  const start = Date.now() - 14 * DAY;
  const span = 7 * DAY;
  for (let i = 0; i < rows.length; i++) {
    await setActivityTime(rows[i].id, start + Math.round((i / Math.max(rows.length - 1, 1)) * span));
  }
  console.log(`  spread ${rows.length} setup events over days 14..7 ago`);
}

async function seedFeedActivity({ users, groups, lists, items }) {
  const byKey = (arr, key) => {
    const found = arr.find((x) => x.key === key);
    if (!found) throw new Error(`Nothing in dev/seed-data.js has the key "${key}"`);
    return found;
  };
  const [alice, ben, carla, diego, erin] = ['alice', 'ben', 'carla', 'diego', 'erin'].map((k) => byKey(users, k));
  const [holiday, games] = ['holiday', 'games'].map((k) => byKey(groups, k));
  const itemFor = (key) => byKey(items, key);

  async function addItem(user, def) {
    const item = await createItem(user, def, lists);
    items.push(item);
    await seedItemImages(item, def.images);
    return item;
  }
  const patchItem = (item, body) => rest('PATCH', `items?id=eq.${item.id}`, { jwt: item.user.jwt, body });
  const editItem = (key) => {
    const { fields, ...body } = FEED.edits[key];
    return patchItem(itemFor(key), fields ? { ...body, custom_fields: customFields(fields) } : body);
  };

  console.log('Seeding feed activity...');
  await spreadSetupActivity();

  await feedStep('Diego edits one of his items', 6 * DAY, () => editItem('keyboard'));

  await feedStep('Erin adds a new item with photos', 5 * DAY, () => addItem(erin, FEED.newItems.runningVest));

  await feedStep("Carla adds an item to Jack's list (a child list)", 4 * DAY, () => addItem(carla, FEED.newItems.legoSpaceship));

  await feedStep('Ben adds a photo to an existing item', 3.5 * DAY, async () => {
    const item = itemFor('pizza-oven');
    await seedItemImage({ item, position: item.images.length, file: FEED.pizzaOvenExtraImage });
  });

  // Alice claims one of Ben's items (claims never appear in the feed), then Ben
  // edits it: Alice sees it as "You claimed this", Ben's feed never does.
  await feedStep("Alice claims one of Ben's items, then Ben edits it", 2.5 * DAY, async () => {
    await rest('POST', 'items_status', { jwt: alice.jwt, body: { item_id: itemFor('dutch-oven').id, user_id: alice.id, status: 'P' } });
    await editItem('dutch-oven');
  });

  // Carla claims one of Diego's items, then Diego archives it: only Carla sees
  // "Diego removed ..., which you claimed".
  await feedStep("Carla claims one of Diego's items, then Diego archives it", 2 * DAY, async () => {
    const item = itemFor('desk-mat');
    await rest('POST', 'items_status', { jwt: carla.jwt, body: { item_id: item.id, user_id: carla.id, status: 'P' } });
    await patchItem(item, { archived: true });
  });

  await feedStep(`Erin leaves ${games.name}`, 1.75 * DAY, async () => {
    await rest('DELETE', `group_members?group_id=eq.${games.id}&user_id=eq.${erin.id}`, { jwt: erin.jwt });
  });

  await feedStep(`Ben adds Erin back to ${games.name}`, 1.25 * DAY, async () => {
    await rest('POST', 'group_members', { jwt: ben.jwt, body: { group_id: games.id, user_id: erin.id, invite: false } });
  });

  await feedStep(`Ben makes Carla a co-owner of ${games.name}`, 1 * DAY, async () => {
    await rest('PATCH', `group_members?group_id=eq.${games.id}&user_id=eq.${carla.id}`, { jwt: ben.jwt, body: { owner: true } });
  });

  // The rename and the new photo happen back to back, so the trigger merges
  // them into one "renamed ... / also changed the group photo" row.
  await feedStep(`Ben renames ${games.name} and changes its photo`, 20 * HOUR, async () => {
    const { name, image } = FEED.gameNightRename;
    await rest('PATCH', `groups?id=eq.${games.id}`, { jwt: ben.jwt, body: { name } });
    games.name = name;
    await seedImage({
      bucket: 'groups', objectName: games.id, jwt: ben.jwt, file: image,
      patchQuery: `groups?id=eq.${games.id}`, tokenField: 'image_token',
    });
  });

  // Everyone is in the holiday group. The draw is a simple shuffled cycle; only
  // the name and date are copied into the feed, never who drew whom.
  await feedStep(`Alice draws Secret Santa in ${holiday.name}`, 8 * HOUR, async () => {
    const order = shuffle(users.map((u) => u.id));
    const drawing = {};
    order.forEach((id, i) => {
      drawing[id] = [order[(i + 1) % order.length]];
    });
    await rest('PATCH', `groups?id=eq.${holiday.id}`, {
      jwt: alice.jwt,
      body: { secret_santa: { status: 'on', name: FEED.secretSantaName, date: formatLongDate(new Date(Date.now() + 10 * DAY)), drawing } },
    });
  });

  await feedStep('Carla updates her bio, and Diego updates his bio and photo', 3 * HOUR, async () => {
    await rest('PATCH', `profiles?user_id=eq.${carla.id}`, { jwt: carla.jwt, body: { bio: FEED.carlaBio } });
    await rest('PATCH', `profiles?user_id=eq.${diego.id}`, { jwt: diego.jwt, body: { bio: FEED.diegoBio } });
    await seedImage({
      bucket: 'avatars', objectName: diego.id, jwt: diego.jwt, file: FEED.diegoAvatar,
      patchQuery: `profiles?user_id=eq.${diego.id}`, tokenField: 'avatar_token',
    });
  });

  await feedStep('Ben adds a new item to his Holiday Wishlist', 40 * MINUTE, () => addItem(ben, FEED.newItems.ticketToRide));

  await feedStep("Carla edits the LEGO set on Jack's list", 10 * MINUTE, () => editItem('lego-spaceship'));

  // Rows in group_members default to "now" and group events only show to
  // members who joined before them, so push every membership into the past
  // (this also covers the re-added member above).
  for (const g of groups) {
    await rest('PATCH', `group_members?group_id=eq.${g.id}`, { jwt: SERVICE_ROLE_KEY, body: { created_at: new Date(Date.now() - 30 * DAY).toISOString() } });
  }

  // Everyone has "seen" the feed up to some point, so the older events are read
  // and the newer ones show as unread badges / dots.
  const seenAgo = [6 * HOUR, 2 * DAY, 2 * DAY, 5 * DAY, 1 * DAY];
  for (let i = 0; i < users.length; i++) {
    await rest('PATCH', `profiles?user_id=eq.${users[i].id}`, { jwt: SERVICE_ROLE_KEY, body: { feed_seen_at: new Date(Date.now() - seenAgo[i]).toISOString() } });
  }
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
  const groups = [];
  for (const g of GROUPS) {
    const owner = users.find((u) => u.key === g.owner);
    const [row] = await rest('POST', 'groups', { jwt: owner.jwt, body: { name: g.name }, prefer: 'return=representation' });
    groups.push({ ...g, id: row.id, owner });
    console.log(`  ${g.name} (${row.id}), owner ${owner.email}`);
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
    for (const { name, child_list, bio, image } of u.lists) {
      const [row] = await rest('POST', 'lists', { jwt: u.jwt, body: { name, bio, user_id: u.id, child_list }, prefer: 'return=representation' });
      lists.push({ id: row.id, user: u, name, image, isDefault: false });
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
  // Interleave the users rather than adding one user's items at a time, so the
  // feed's "added" events (spread out in this order) read like everyone chipping in.
  const queue = users.flatMap((user) => user.items.map((def, i) => ({ user, def, order: (i + 0.5) / user.items.length })));
  queue.sort((a, b) => a.order - b.order);
  for (const { user, def } of queue) items.push(await createItem(user, def, lists));
  console.log(`  ${items.length} items created`);

  console.log('Uploading avatar images...');
  for (const u of users) {
    await seedImage({
      bucket: 'avatars', objectName: u.id, jwt: u.jwt, file: u.avatar,
      patchQuery: `profiles?user_id=eq.${u.id}`, tokenField: 'avatar_token',
    });
  }

  console.log('Uploading group images...');
  for (const g of groups) {
    await seedImage({
      bucket: 'groups', objectName: g.id, jwt: g.owner.jwt, file: g.image,
      patchQuery: `groups?id=eq.${g.id}`, tokenField: 'image_token',
    });
  }

  console.log('Uploading list images...');
  // The lists storage bucket's RLS policy (is_list_owner in 0005-items.sql)
  // keys objects by the bare list id, and every user's auto-created list
  // uses the literal id 'default' - so a 'default' object would collide
  // across every user. Only the extra, uniquely-id'd lists get images.
  for (const l of lists.filter((l) => l.image)) {
    await seedImage({
      bucket: 'lists', objectName: l.id, jwt: l.user.jwt, file: l.image,
      patchQuery: `lists?id=eq.${l.id}&user_id=eq.${l.user.id}`, tokenField: 'avatar_token',
    });
  }

  console.log('Uploading item images...');
  for (const it of items) await seedItemImages(it, it.images);

  await seedFeedActivity({ users, groups, lists, items });

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
