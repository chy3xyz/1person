"use client";

import { useQuery } from "@tanstack/react-query";
import { useWorkspaceId } from "@1person/core/hooks";
import type { CommissionRule } from "@1person/core/types";
import { Button } from "@1person/ui/components/ui/button";

export function CommissionPage() {
  const wsId = useWorkspaceId();

  const { data: rules = [] } = useQuery<CommissionRule[]>({
    queryKey: ["commission-rules", wsId],
    queryFn: async () => {
      const res = await fetch(`/api/commissions/rules`, {
        headers: { "X-Workspace-Id": wsId },
      });
      const json = await res.json();
      return json.rules ?? [];
    },
    enabled: !!wsId,
  });

  if (!rules.length) {
    return (
      <div className="p-8 text-center text-muted-foreground">
        No commission rules configured yet.
        <br />
        <Button variant="outline" className="mt-4">
          Create your first rule
        </Button>
      </div>
    );
  }

  return (
    <div className="space-y-4 p-4">
      {rules.map((rule: any) => (
        <div key={rule.id} className="rounded-lg border p-4">
          <h3 className="font-semibold">{rule.name}</h3>
          <div className="mt-2 text-sm text-muted-foreground">
            {(rule.levels ?? []).map((l: any) => (
              <span key={l.depth} className="mr-3">
                L{l.depth}: {(l.rate * 100).toFixed(0)}%
              </span>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
