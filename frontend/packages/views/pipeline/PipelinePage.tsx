"use client";

import { useQuery } from "@tanstack/react-query";
import { useWorkspaceId } from "@1person/core/hooks";
import type { PipelineConfig } from "@1person/core/types";
import { Button } from "@1person/ui/components/ui/button";

export function PipelinePage() {
  const wsId = useWorkspaceId();

  const { data = [] } = useQuery<PipelineConfig[]>({
    queryKey: ["pipelines", wsId],
    queryFn: async () => {
      const res = await fetch(`/api/pipelines`, {
        headers: { "X-Workspace-Id": wsId },
      });
      const json = await res.json();
      return json.pipelines ?? [];
    },
    enabled: !!wsId,
  });

  if (!data.length) {
    return (
      <div className="p-8 text-center text-muted-foreground">
        No pipelines configured yet.
        <br />
        <Button variant="outline" className="mt-4">
          Create your first pipeline
        </Button>
      </div>
    );
  }

  return (
    <div className="space-y-4 p-4">
      {data.map((pipe: any) => (
        <div key={pipe.id} className="rounded-lg border p-4">
          <h3 className="font-semibold">{pipe.name}</h3>
          <p className="text-sm text-muted-foreground">{pipe.description}</p>
          <div className="mt-2 flex items-center gap-2">
            <span className="text-xs text-muted-foreground">
              {pipe.phase_count} phases · Created {pipe.created_at}
            </span>
          </div>
        </div>
      ))}
    </div>
  );
}
