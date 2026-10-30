-- Backfill `issue.assignee_type` for rows written before the update
-- path learned to persist it.
--
-- The wire contract carries the assignee as a (type, id) tuple: the
-- client renders agents differently from members, and an issue whose
-- type is missing reads as unassigned no matter what the id points at.
-- The update path used to write only the id, so every issue assigned to
-- an agent through the API ended up with `assignee_type IS NULL` and
-- `assignee_id` set — a half-pair that the client cannot render and
-- that the backend now rejects.
--
-- The type is derived from what the id actually is. A row whose id
-- matches nothing (a deleted agent, a stale member) keeps the null
-- type: inventing one would be a guess.
UPDATE issue i
SET assignee_type = 'agent'
WHERE i.assignee_type IS NULL
  AND i.assignee_id IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM agent a
      WHERE a.id = i.assignee_id AND a.workspace_id = i.workspace_id
  );

UPDATE issue i
SET assignee_type = 'member'
WHERE i.assignee_type IS NULL
  AND i.assignee_id IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM member m
      WHERE m.user_id = i.assignee_id AND m.workspace_id = i.workspace_id
  );

UPDATE issue i
SET assignee_type = 'squad'
WHERE i.assignee_type IS NULL
  AND i.assignee_id IS NOT NULL
  AND EXISTS (
      SELECT 1 FROM squad s
      WHERE s.id = i.assignee_id AND s.workspace_id = i.workspace_id
  );
