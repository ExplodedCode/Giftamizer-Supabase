// One-off migration script for the item multi-image feature.
//
// Moves every existing item image object in the `items` storage bucket from
// its old flat path ("{itemId}") to the new nested path
// ("{itemId}/{itemImagesId}") that the new item_images-based RLS and
// frontend code expect. Must be run AFTER applying
// volumes/db/giftamizer/0014-item-multi-images.sql (which creates the
// item_images rows this script reads) and BEFORE deploying the new
// frontend (which only knows how to read the new nested path).
//
// No npm dependencies - this repo has no Node toolchain of its own, so this
// talks to PostgREST (to read item_images) and the Storage API (to move
// objects) directly over HTTP with Node's built-in fetch. Requires Node 18+.
//
// Usage:
//   SUPABASE_URL=http://localhost:8000 \
//   SERVICE_ROLE_KEY=<service role key from backend/.env> \
//   node scripts/migrate-item-images.mjs [--prune-missing]
//
// How each item_images row is handled (decided by checking what actually
// exists in storage, never by guessing from an HTTP status):
//   - destination "{itemId}/{imageId}" already exists -> already migrated, skipped
//   - else a leftover "_migrate/{itemId}" exists      -> an earlier run died
//                                                        between hops, finish it
//   - else the flat "{itemId}" object exists          -> move it
//   - else there is nothing to move                   -> reported as MISSING
//                                                        (a ghost row from the
//                                                        0014 backfill: the item
//                                                        had image_token set but
//                                                        no file). Left alone
//                                                        unless --prune-missing
//                                                        is passed, which deletes
//                                                        the row.
//
// The move is done in two hops via a temporary "_migrate/{itemId}" key rather
// than "{itemId}" -> "{itemId}/{imageId}" directly: that direct move makes the
// source key a path prefix of the destination, which some storage backends
// (e.g. file-based) can't represent while the source still exists. "_migrate"
// is not a uuid, so no storage policy ever grants a user access to it. Every
// move is verified by checking the destination exists afterwards, and any
// non-OK response is a hard failure - nothing is silently treated as "skipped".
//
// Safe to re-run.

const SUPABASE_URL = (process.env.SUPABASE_URL ?? 'http://localhost:8000').replace(/\/$/, '');
const SERVICE_ROLE_KEY = process.env.SERVICE_ROLE_KEY;
const PRUNE_MISSING = process.argv.includes('--prune-missing');

if (!SERVICE_ROLE_KEY) {
	console.error('SERVICE_ROLE_KEY env var is required (find it in backend/.env).');
	process.exit(1);
}

const authHeaders = {
	apikey: SERVICE_ROLE_KEY,
	Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
};

async function fetchAllItemImages() {
	const pageSize = 1000;
	let offset = 0;
	const rows = [];

	while (true) {
		const res = await fetch(`${SUPABASE_URL}/rest/v1/item_images?select=id,item_id&order=created_at.asc,id.asc&offset=${offset}&limit=${pageSize}`, {
			headers: authHeaders,
		});
		if (!res.ok) {
			throw new Error(`Failed to fetch item_images (offset ${offset}): ${res.status} ${await res.text()}`);
		}
		const page = await res.json();
		rows.push(...page);
		if (page.length < pageSize) break;
		offset += pageSize;
	}

	return rows;
}

// True/false for "does this object exist"; throws on anything that isn't a
// clear yes (200) or no (400/404), so a transient server error can never be
// mistaken for "missing".
async function objectExists(key) {
	const res = await fetch(`${SUPABASE_URL}/storage/v1/object/authenticated/items/${key}`, {
		headers: { ...authHeaders, Range: 'bytes=0-0' },
	});
	// We only need the status; don't download the body.
	await res.body?.cancel();

	if (res.ok) return true; // 200 or 206
	if (res.status === 404 || res.status === 400) return false;
	throw new Error(`Unexpected response checking ${key}: ${res.status}`);
}

async function moveObject(fromKey, toKey) {
	const res = await fetch(`${SUPABASE_URL}/storage/v1/object/move`, {
		method: 'POST',
		headers: { ...authHeaders, 'Content-Type': 'application/json' },
		body: JSON.stringify({ bucketId: 'items', sourceKey: fromKey, destinationKey: toKey }),
	});
	if (!res.ok) throw new Error(`Move ${fromKey} -> ${toKey} failed: ${res.status} ${await res.text()}`);
}

async function deleteRow(id) {
	const res = await fetch(`${SUPABASE_URL}/rest/v1/item_images?id=eq.${id}`, { method: 'DELETE', headers: authHeaders });
	if (!res.ok) throw new Error(`Failed to delete item_images row ${id}: ${res.status} ${await res.text()}`);
}

async function migrateOne({ id, item_id }) {
	const flatKey = `${item_id}`;
	const tempKey = `_migrate/${item_id}`;
	const finalKey = `${item_id}/${id}`;

	if (await objectExists(finalKey)) return 'skipped';

	if (await objectExists(tempKey)) {
		await moveObject(tempKey, finalKey);
	} else if (await objectExists(flatKey)) {
		await moveObject(flatKey, tempKey);
		await moveObject(tempKey, finalKey);
	} else {
		return 'missing';
	}

	if (!(await objectExists(finalKey))) throw new Error(`Move reported success but ${finalKey} does not exist`);
	return 'moved';
}

async function main() {
	const itemImages = await fetchAllItemImages();
	console.log(`Found ${itemImages.length} item_images row(s) to reconcile.${PRUNE_MISSING ? ' (--prune-missing: rows with no file will be deleted)' : ''}`);

	const counts = { moved: 0, skipped: 0, missing: 0, pruned: 0, failed: 0 };

	for (const row of itemImages) {
		const finalKey = `${row.item_id}/${row.id}`;
		try {
			const result = await migrateOne(row);
			if (result === 'moved') {
				counts.moved++;
				console.log(`moved   ${row.item_id} -> ${finalKey}`);
			} else if (result === 'skipped') {
				counts.skipped++;
				console.log(`skipped ${finalKey} (already migrated)`);
			} else if (PRUNE_MISSING) {
				await deleteRow(row.id);
				counts.pruned++;
				console.log(`pruned  ${finalKey} (no file in storage, row deleted)`);
			} else {
				counts.missing++;
				console.warn(`MISSING ${row.item_id} (no file in storage for item_images row ${row.id}; re-run with --prune-missing to delete the row)`);
			}
		} catch (err) {
			counts.failed++;
			console.error(`FAILED  ${finalKey}: ${err.message}`);
		}
	}

	console.log(`\nDone. moved=${counts.moved} skipped=${counts.skipped} missing=${counts.missing} pruned=${counts.pruned} failed=${counts.failed}`);
	if (counts.failed > 0) process.exit(1);
}

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
