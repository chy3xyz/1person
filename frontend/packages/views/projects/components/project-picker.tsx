"use client";

import { Check, FolderKanban, X } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { projectListOptions } from "@1person/core/projects/queries";
import { useWorkspaceId } from "@1person/core/hooks";
import type { UpdateIssueRequest } from "@1person/core/types";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
} from "@1person/ui/components/ui/dropdown-menu";
import { ProjectIcon } from "./project-icon";
import { useT } from "../../i18n";

export function ProjectPicker({
  projectId,
  onUpdate,
  triggerRender,
  align = "start",
  defaultOpen = false,
}: {
  projectId: string | null;
  onUpdate: (updates: Partial<UpdateIssueRequest>) => void;
  triggerRender?: React.ReactElement;
  align?: "start" | "center" | "end";
  /** Open the dropdown on first mount. Used by progressive-disclosure
   *  sidebars so a newly-added field immediately enters edit state. */
  defaultOpen?: boolean;
}) {
  const { t } = useT("projects");
  const wsId = useWorkspaceId();
  const { data: projects = [] } = useQuery(projectListOptions(wsId));
  const current = projects.find((p) => p.id === projectId);

  return (
    <DropdownMenu defaultOpen={defaultOpen}>
      <DropdownMenuTrigger
        className={triggerRender ? undefined : "flex items-center gap-1.5 cursor-pointer rounded px-1 -mx-1 hover:bg-accent/30 transition-colors overflow-hidden"}
        render={triggerRender}
      >
        {current ? (
          <ProjectIcon project={current} size="sm" />
        ) : (
          <FolderKanban className="h-3.5 w-3.5 shrink-0 text-muted-foreground" />
        )}
        <span className="truncate">{current ? current.title : t(($) => $.picker.no_project)}</span>
      </DropdownMenuTrigger>
      <DropdownMenuContent align={align} className="w-52">
        {projects.map((p) => (
          <DropdownMenuItem
            key={p.id}
            onClick={() => onUpdate({ project_id: p.id })}
            // PATCH (MUL-7575 parity): surface the project description in the
            // picker so users don't have to open each project to remember
            // which is which. We trim truncation for >2 lines and use the
            // native `title` attr for the full tooltip when hovering.
            title={p.description ?? undefined}
            className="items-start"
          >
            <ProjectIcon project={p} size="md" className="mt-0.5 mr-1" />
            <div className="min-w-0 flex-1">
              <div className="flex items-center gap-1.5">
                <span className="truncate font-medium">{p.title}</span>
                {p.id === projectId && <Check className="h-3.5 w-3.5 shrink-0" />}
              </div>
              {p.description && (
                <div className="mt-0.5 line-clamp-2 text-xs text-muted-foreground">
                  {p.description}
                </div>
              )}
            </div>
          </DropdownMenuItem>
        ))}
        {projects.length > 0 && projectId && <DropdownMenuSeparator />}
        {projectId && (
          <DropdownMenuItem onClick={() => onUpdate({ project_id: null })}>
            <X className="h-3.5 w-3.5 text-muted-foreground" />
            {t(($) => $.picker.remove)}
          </DropdownMenuItem>
        )}
        {projects.length === 0 && (
          <div className="px-2 py-1.5 text-xs text-muted-foreground">{t(($) => $.picker.empty)}</div>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
