import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const pipelineKeys = {
  all: (wsId: string) => ["pipelines", wsId] as const,
  list: (wsId: string) => [...pipelineKeys.all(wsId), "list"] as const,
  detail: (wsId: string, id: string) =>
    [...pipelineKeys.all(wsId), "detail", id] as const,
  runs: (wsId: string, id: string) =>
    [...pipelineKeys.all(wsId), "runs", id] as const,
  run: (wsId: string, id: string, runId: string) =>
    [...pipelineKeys.all(wsId), "runs", id, runId] as const,
};

export function pipelineListOptions(wsId: string) {
  return queryOptions({
    queryKey: pipelineKeys.list(wsId),
    queryFn: () => api.listPipelineConfigs(),
  });
}

export function pipelineDetailOptions(wsId: string, id: string) {
  return queryOptions({
    queryKey: pipelineKeys.detail(wsId, id),
    queryFn: () => api.getPipelineConfig(id),
  });
}

export function pipelineRunsOptions(wsId: string, id: string) {
  return queryOptions({
    queryKey: pipelineKeys.runs(wsId, id),
    queryFn: () => api.listPipelineRuns(id),
  });
}

// pipelineRunOptions fetches a single run with full details.
// The list endpoint (pipelineRunsOptions) may omit heavy payloads to keep
// list responses small; callers use this query on demand for drill-down.
export function pipelineRunOptions(
  wsId: string,
  id: string,
  runId: string,
  options?: { enabled?: boolean },
) {
  return queryOptions({
    queryKey: pipelineKeys.run(wsId, id, runId),
    queryFn: () => api.getPipelineRun(id, runId),
    enabled: options?.enabled ?? true,
  });
}
