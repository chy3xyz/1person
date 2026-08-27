"use client";

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "..";
import { useWorkspaceId } from "../../hooks";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

const pipelineKeys = {
  all: (wsId: string) => ["pipelines", wsId] as const,
  list: (wsId: string) => [...pipelineKeys.all(wsId), "list"] as const,
  detail: (wsId: string, id: string) =>
    [...pipelineKeys.all(wsId), "detail", id] as const,
  runs: (wsId: string, id: string) =>
    [...pipelineKeys.all(wsId), "runs", id] as const,
  run: (wsId: string, id: string, runId: string) =>
    [...pipelineKeys.all(wsId), "runs", id, runId] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

function pipelineConfigListOptions(wsId: string) {
  return {
    queryKey: pipelineKeys.list(wsId),
    queryFn: () => api.listPipelineConfigs(),
  };
}

function pipelineRunListOptions(wsId: string, id: string) {
  return {
    queryKey: pipelineKeys.runs(wsId, id),
    queryFn: () => api.listPipelineRuns(id),
  };
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of pipeline configs for the current workspace. */
export function usePipelineConfigs() {
  const wsId = useWorkspaceId();
  return useQuery(pipelineConfigListOptions(wsId));
}

/** Creates a new pipeline config and optimistically updates the list cache. */
export function useCreatePipeline() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: Record<string, unknown>) => api.createPipelineConfig(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: pipelineKeys.list(wsId) });
    },
  });
}

/** Starts a pipeline run for the given config and invalidates the runs list. */
export function useStartPipeline() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (id: string) => api.startPipelineRun(id),
    onSettled: (_data, _err, id) => {
      qc.invalidateQueries({ queryKey: pipelineKeys.runs(wsId, id) });
      qc.invalidateQueries({ queryKey: pipelineKeys.detail(wsId, id) });
    },
  });
}

/** Fetches the list of runs for a given pipeline config. */
export function usePipelineRuns(id: string) {
  const wsId = useWorkspaceId();
  return useQuery({
    ...pipelineRunListOptions(wsId, id),
    enabled: !!id,
  });
}

/** Completes a phase within a pipeline run and invalidates the run cache. */
export function useCompletePhase() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: ({
      id,
      runId,
      phaseId,
    }: {
      id: string;
      runId: string;
      phaseId: string;
    }) => api.completePipelinePhase(id, runId, phaseId),
    onSettled: (_data, _err, { id, runId }) => {
      qc.invalidateQueries({ queryKey: pipelineKeys.runs(wsId, id) });
      qc.invalidateQueries({ queryKey: pipelineKeys.run(wsId, id, runId) });
    },
  });
}
