import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { pipelineKeys } from "./queries";
import { useWorkspaceId } from "../hooks";

export function useCreatePipeline() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: Record<string, unknown>) =>
      api.createPipelineConfig(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: pipelineKeys.list(wsId) });
    },
  });
}

export function useUpdatePipeline() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: ({ id, ...data }: { id: string; [key: string]: unknown }) =>
      api.updatePipelineConfig(id, data as Record<string, unknown>),
    onMutate: async ({ id, ...data }) => {
      await qc.cancelQueries({ queryKey: pipelineKeys.list(wsId) });
      const prevList = qc.getQueryData(pipelineKeys.list(wsId));
      const prevDetail = qc.getQueryData(pipelineKeys.detail(wsId, id));

      qc.setQueryData(pipelineKeys.list(wsId), (old: any) => {
        if (!old) return old;
        const configs = Array.isArray(old)
          ? old.map((c: any) => (c.id === id ? { ...c, ...data } : c))
          : old.configs
            ? {
                ...old,
                configs: old.configs.map((c: any) =>
                  c.id === id ? { ...c, ...data } : c,
                ),
              }
            : old;
        return configs;
      });

      qc.setQueryData(pipelineKeys.detail(wsId, id), (old: any) =>
        old ? { ...old, ...data } : old,
      );

      return { prevList, prevDetail, id };
    },
    onError: (_err, _vars, ctx) => {
      if (ctx?.prevList)
        qc.setQueryData(pipelineKeys.list(wsId), ctx.prevList);
      if (ctx?.prevDetail && ctx?.id)
        qc.setQueryData(pipelineKeys.detail(wsId, ctx.id), ctx.prevDetail);
    },
    onSettled: (_data, _err, vars) => {
      qc.invalidateQueries({ queryKey: pipelineKeys.detail(wsId, vars.id) });
      qc.invalidateQueries({ queryKey: pipelineKeys.list(wsId) });
    },
  });
}

export function useDeletePipeline() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (id: string) => api.deletePipelineConfig(id),
    onMutate: async (id) => {
      await qc.cancelQueries({ queryKey: pipelineKeys.list(wsId) });
      const prevList = qc.getQueryData(pipelineKeys.list(wsId));

      qc.setQueryData(pipelineKeys.list(wsId), (old: any) => {
        if (!old) return old;
        if (Array.isArray(old)) return old.filter((c: any) => c.id !== id);
        if (old.configs)
          return { ...old, configs: old.configs.filter((c: any) => c.id !== id) };
        return old;
      });

      qc.removeQueries({ queryKey: pipelineKeys.detail(wsId, id) });
      return { prevList };
    },
    onError: (_err, _id, ctx) => {
      if (ctx?.prevList)
        qc.setQueryData(pipelineKeys.list(wsId), ctx.prevList);
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: pipelineKeys.list(wsId) });
    },
  });
}

export function useStartPipelineRun() {
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

export function useCompletePipelinePhase() {
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
