"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { FolderGit2, Loader2, Save, X } from "lucide-react";
import type { Agent } from "@1person/core/types";
import {
  localPathEquals,
  parseLocalPath,
  withLocalPath,
} from "@1person/core/agents";
import { Button } from "@1person/ui/components/ui/button";
import { Input } from "@1person/ui/components/ui/input";
import { Label } from "@1person/ui/components/ui/label";
import { toast } from "sonner";
import { useT } from "../../../i18n";

/**
 * The local repository an agent works in.
 *
 * The path lives in `agent.runtime_config.local_path`. The daemon reads it
 * when it claims a task: the task gets its own git worktree inside that
 * repository, the agent edits the worktree, and the platform commits the
 * result onto a `1p/<agent>/<task>` branch. The user's own working copy is
 * never touched — the agent never commits either, the platform does.
 */
export function LocalDirectoryTab({
  agent,
  onSave,
  onDirtyChange,
}: {
  agent: Agent;
  onSave: (updates: { runtime_config: Record<string, unknown> }) => Promise<void>;
  onDirtyChange?: (dirty: boolean) => void;
}) {
  const { t } = useT("agents");

  const original = useMemo(() => agent.runtime_config, [agent.runtime_config]);
  const originalPath = useMemo(() => parseLocalPath(original), [original]);

  const [path, setPath] = useState(originalPath);
  const [saving, setSaving] = useState(false);

  // Adopt the server value only while the user has no edits of their own —
  // the same pattern the other config tabs use, so a refetch that lands
  // mid-edit doesn't wipe what the user typed.
  const previousPathRef = useRef(originalPath);
  useEffect(() => {
    setPath((current) =>
      current === previousPathRef.current ? originalPath : current,
    );
    previousPathRef.current = originalPath;
  }, [originalPath]);

  const dirty = !localPathEquals(original, { local_path: path });
  useEffect(() => {
    onDirtyChange?.(dirty);
  }, [dirty, onDirtyChange]);

  // A relative path would be resolved against the daemon's own working
  // directory, which is nowhere the user expects. Only absolute paths are
  // accepted.
  const trimmed = path.trim();
  const absolute = trimmed === "" || trimmed.startsWith("/");
  const canSave = absolute && !saving;

  const handleSave = async (nextPath: string) => {
    const next = nextPath.trim();
    if (saving) return;
    if (next !== "" && !next.startsWith("/")) return;
    setSaving(true);
    try {
      await onSave({
        runtime_config: withLocalPath(original, next),
      });
      toast.success(t(($) => $.tab_body.local_directory.saved_toast));
    } catch (err) {
      toast.error(
        err instanceof Error && err.message
          ? err.message
          : t(($) => $.tab_body.local_directory.save_failed_toast),
      );
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="flex h-full flex-col space-y-4">
      <p className="text-xs text-muted-foreground">
        {t(($) => $.tab_body.local_directory.intro)}
      </p>

      <div className="space-y-1.5">
        <Label htmlFor="agent-local-path" className="text-xs">
          {t(($) => $.tab_body.local_directory.path_label)}
        </Label>
        <div className="flex items-center gap-2">
          <Input
            id="agent-local-path"
            value={path}
            onChange={(e) => setPath(e.target.value)}
            placeholder={t(($) => $.tab_body.local_directory.path_placeholder)}
            aria-invalid={!absolute || undefined}
            className="font-mono text-xs"
          />
          {originalPath !== "" && (
            <Button
              type="button"
              variant="ghost"
              size="sm"
              disabled={saving}
              onClick={() => {
                setPath("");
                void handleSave("");
              }}
            >
              <X className="h-3.5 w-3.5" />
              {t(($) => $.tab_body.local_directory.clear)}
            </Button>
          )}
        </div>
        {!absolute && (
          <p className="text-xs text-destructive">
            {t(($) => $.tab_body.local_directory.path_not_absolute)}
          </p>
        )}
        <p className="text-xs text-muted-foreground">
          {t(($) => $.tab_body.local_directory.path_hint)}
        </p>
      </div>

      {originalPath !== "" && (
        <div className="space-y-1.5 rounded-md border p-3">
          <div className="flex items-center gap-1.5">
            <FolderGit2 className="h-3.5 w-3.5 text-muted-foreground" />
            <span className="text-xs font-medium">
              {t(($) => $.tab_body.local_directory.current_label)}
            </span>
          </div>
          <p className="font-mono text-xs text-muted-foreground">{originalPath}</p>
        </div>
      )}

      <div className="flex items-center justify-end gap-3 pt-2">
        {dirty && (
          <span className="text-xs text-muted-foreground">
            {t(($) => $.tab_body.common.unsaved_changes)}
          </span>
        )}
        <Button
          onClick={() => void handleSave(path)}
          disabled={!dirty || !canSave}
          size="sm"
        >
          {saving ? (
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
          ) : (
            <Save className="h-3.5 w-3.5" />
          )}
          {t(($) => $.tab_body.common.save)}
        </Button>
      </div>
    </div>
  );
}
