-- Item status is normally hidden from the item's owner (that's the whole
-- point - so you can't see what people are getting you). Child lists
-- (`lists.child_list = true`, "Display Separately in Groups" - wishlists a
-- parent manages on behalf of a kid) are different: the list owner isn't the
-- gift recipient, so there's no surprise to protect, and hiding status just
-- means the owner can't tell an item is already claimed before suggesting it
-- to someone else. Let the owner view and update item_status rows for items
-- on their own child lists; everything else keeps the existing owner-blind
-- behavior.

CREATE OR REPLACE FUNCTION is_child_list_item(itemid UUID, userid UUID)
RETURNS BOOLEAN AS $$
  SELECT EXISTS (
    SELECT 1
    FROM items i
    JOIN items_lists il ON il.item_id = i.id
    JOIN lists l ON l.id = il.list_id AND l.user_id = il.user_id
    WHERE i.id = itemid
      AND i.user_id = userid
      AND l.user_id = userid
      AND l.child_list = true
  );
$$ LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION can_view_item_status(userid UUID, itemid UUID)
RETURNS BOOL AS $$
DECLARE
  item_row record;
  enable_lists boolean;
BEGIN
  SELECT * INTO item_row FROM items WHERE items.id = itemid;
  SELECT profiles.enable_lists INTO enable_lists FROM profiles WHERE profiles.user_id = item_row.user_id;

  IF item_row.shopping_item IS NOT NULL AND item_row.user_id = userid THEN
    RETURN true;
  END IF;

  IF item_row IS NULL THEN
    RETURN false;
  END IF;

  IF item_row.user_id = userid THEN
    RETURN is_child_list_item(itemid, userid);
  END IF;

  IF enable_lists = true THEN
    RETURN EXISTS (
      SELECT 1
      FROM group_members
      JOIN lists_groups ON lists_groups.group_id = group_members.group_id
      JOIN items_lists ON items_lists.list_id = lists_groups.list_id
      WHERE
        group_members.user_id = userid
        AND items_lists.item_id = itemid
    );
  ELSE
    RETURN EXISTS (
      SELECT 1
      FROM group_members gm1
      JOIN group_members gm2 ON gm1.group_id = gm2.group_id
      WHERE
        gm1.user_id = userid
        AND gm2.user_id = (SELECT user_id FROM items WHERE id = itemid) AND gm2.invite = false
    );
  END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION can_view_item_status(itemid UUID)
RETURNS BOOL AS $$
DECLARE
  item_row record;
  enable_lists boolean;
BEGIN
  SELECT * INTO item_row FROM items WHERE items.id = itemid;
  SELECT profiles.enable_lists INTO enable_lists FROM profiles WHERE profiles.user_id = item_row.user_id;

  IF item_row IS NULL THEN
    RETURN false;
  END IF;

  IF item_row.user_id = auth.uid() THEN
    RETURN is_child_list_item(itemid, auth.uid());
  END IF;

  IF enable_lists = true THEN
    RETURN EXISTS (
      SELECT 1
      FROM group_members
      JOIN lists_groups ON lists_groups.group_id = group_members.group_id
      JOIN items_lists ON items_lists.list_id = lists_groups.list_id
      WHERE
        group_members.user_id = auth.uid()
        AND items_lists.item_id = itemid
    );
  ELSE
    RETURN EXISTS (
      SELECT 1
      FROM group_members gm1
      JOIN group_members gm2 ON gm1.group_id = gm2.group_id
      WHERE
        gm1.user_id = auth.uid()
        AND gm2.user_id = (SELECT user_id FROM items WHERE id = itemid) AND gm2.invite = false
    );
  END IF;
END;
$$ LANGUAGE plpgsql;

DROP POLICY IF EXISTS "Do not allow item owner to view items_status" ON items_status;
CREATE POLICY "Allow select items_status"
  ON items_status FOR SELECT
  TO authenticated
  USING (can_view_item_status(auth.uid(), item_id));

-- The frontend claims via upsert() - when no row exists yet for an item,
-- that's an INSERT, still gated by can_claim_item(), which explicitly
-- returns false for the item's own owner (correct for regular items, wrong
-- for child-list ones). Let the owner insert too, so they can set the
-- initial status on their own child-list items.
DROP POLICY IF EXISTS "Allow insert if can claim item" ON items_status;
CREATE POLICY "Allow insert if can claim item"
  ON items_status FOR INSERT
  TO authenticated
  WITH CHECK (can_claim_item(auth.uid(), item_id) OR is_child_list_item(item_id, auth.uid()));

-- Deliberately NOT touching "Allow update items_status row" (still
-- `user_id = auth.uid()` only, from 0007). An upsert() against an
-- already-claimed item hits UPDATE, not INSERT (item_id is the PK) - if the
-- owner's UPDATE were also gated by is_child_list_item, they could silently
-- overwrite another member's existing claim just by clicking "claim" on an
-- already-claimed item. Leaving UPDATE owner-blind means the owner can only
-- ever touch a row they created themselves (i.e. their own INSERT above),
-- same as any other claimant - first claim always wins.
