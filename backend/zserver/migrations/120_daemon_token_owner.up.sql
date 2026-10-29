-- The daemon token now records who paired the machine. Upstream parity:
-- `server/internal/handler/daemon.go` reads the token owner from the
-- request context (DaemonTokenOwnerIDFromContext) and writes it to
-- `agent_runtime.owner_id` at registration, with a `required_owner_id`
-- fence so a re-registering daemon cannot steal the row from its owner.
--
-- Without an owner the runtime row stays ownerless, and an ownerless
-- runtime is unusable: the runtime picker filters to "mine"
-- (`owner_id === currentUser`) and marks anything else as locked, so a
-- paired daemon never shows up in the picker and agent creation stays
-- disabled.
ALTER TABLE daemon_token
    ADD COLUMN IF NOT EXISTS owner_id UUID REFERENCES "user"(id) ON DELETE SET NULL;

-- Backfill for tokens minted before this migration: they carry no
-- recorded owner, so fall back to the workspace owner. A token is always
-- minted by a member of the workspace it is bound to, so the workspace
-- owner is the closest durable identity available. (The fork stores the
-- workspace owner in `member.role = 'owner'`, not on the workspace row.)
UPDATE daemon_token dt
SET owner_id = (
    SELECT m.user_id FROM member m
    WHERE m.workspace_id = dt.workspace_id AND m.role = 'owner'
    ORDER BY m.created_at LIMIT 1
)
WHERE dt.owner_id IS NULL
  AND EXISTS (
    SELECT 1 FROM member m
    WHERE m.workspace_id = dt.workspace_id AND m.role = 'owner'
  );

-- Same backfill for runtimes registered before this migration: they are
-- ownerless for the exact reason this migration exists, which makes
-- them invisible to the picker's "mine" filter. Adopt the workspace
-- owner so existing daemons become selectable again.
UPDATE agent_runtime r
SET owner_id = (
    SELECT m.user_id FROM member m
    WHERE m.workspace_id = r.workspace_id AND m.role = 'owner'
    ORDER BY m.created_at LIMIT 1
)
WHERE r.owner_id IS NULL
  AND EXISTS (
    SELECT 1 FROM member m
    WHERE m.workspace_id = r.workspace_id AND m.role = 'owner'
  );
