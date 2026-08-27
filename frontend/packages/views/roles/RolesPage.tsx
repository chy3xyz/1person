"use client";

import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Shield, GitBranch } from "lucide-react";
import { useWorkspaceId } from "@1person/core/hooks";

function TabButton({
  active,
  onClick,
  label,
  count,
}: {
  active: boolean;
  onClick: () => void;
  label: string;
  count?: number;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`px-3 py-2 text-sm font-medium border-b-2 transition-colors ${
        active
          ? "border-primary text-primary"
          : "border-transparent text-muted-foreground hover:text-foreground"
      }`}
    >
      {label}
      {count != null && (
        <span className="ml-1 text-xs text-muted-foreground">({count})</span>
      )}
    </button>
  );
}

export function RolesPage() {
  const wsId = useWorkspaceId();
  const [tab, setTab] = useState<"definitions" | "members" | "hierarchy">("definitions");

  const fetchDefs = () =>
    fetch(`/api/roles/defs`, { headers: { "X-Workspace-Id": wsId } })
      .then((r) => r.json())
      .then((j) => (j.defs ?? []) as any[]);

  const fetchMembers = () =>
    fetch(`/api/roles/members`, { headers: { "X-Workspace-Id": wsId } })
      .then((r) => r.json())
      .then((j) => (j.members ?? []) as any[]);

  const defs = useQuery({
    queryKey: ["roles", wsId, "defs"],
    queryFn: fetchDefs,
    enabled: !!wsId,
  });

  const members = useQuery({
    queryKey: ["roles", wsId, "members"],
    queryFn: fetchMembers,
    enabled: !!wsId,
  });

  const defCount = (defs.data as any[])?.length;
  const memberCount = (members.data as any[])?.length;

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center justify-between px-5 py-3">
        <div className="flex items-center gap-2">
          <Shield className="h-4 w-4 text-muted-foreground" />
          <h1 className="text-sm font-medium">Roles</h1>
        </div>
      </header>

      <div className="flex gap-0 border-b px-5">
        <TabButton active={tab === "definitions"} onClick={() => setTab("definitions")} label="Definitions" count={defCount} />
        <TabButton active={tab === "members"} onClick={() => setTab("members")} label="Members" count={memberCount} />
        <TabButton active={tab === "hierarchy"} onClick={() => setTab("hierarchy")} label="Hierarchy" />
      </div>

      <div className="flex-1 overflow-y-auto p-5">
        {tab === "definitions" && (
          <div>
            {defs.isLoading && <p className="text-muted-foreground">Loading...</p>}
            {(defs.data as any[])?.map((d: any) => (
              <div key={d.id} className="rounded-lg border p-3 mb-2">
                <span className="font-medium">{d.name}</span>
                <span className="ml-2 text-xs text-muted-foreground">
                  L{d.level} · {(d.permissions as string[])?.join(", ")}
                </span>
              </div>
            ))}
          </div>
        )}

        {tab === "members" && (
          <div>
            {members.isLoading && <p className="text-muted-foreground">Loading...</p>}
            {(members.data as any[])?.map((m: any) => (
              <div key={m.user_id} className="rounded-lg border p-3 mb-2">
                <span className="font-medium">{m.user_id}</span>
                <span className="ml-2 text-xs">role: {m.role}</span>
                <span className="ml-2 text-xs text-muted-foreground">L{m.level}</span>
              </div>
            ))}
          </div>
        )}

        {tab === "hierarchy" && (
          <div className="p-8 text-center text-muted-foreground">
            <GitBranch className="h-8 w-8 mx-auto mb-2 opacity-30" />
            <p>Select a member to view their hierarchy tree.</p>
          </div>
        )}
      </div>
    </div>
  );
}
