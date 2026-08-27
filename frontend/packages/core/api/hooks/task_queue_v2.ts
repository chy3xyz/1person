"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const taskQueueV2Keys = {
  all: () => ["task_queue_v2"] as const,
  stats: () => [...taskQueueV2Keys.all(), "stats"] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function queueStatsOptions() {
  return queryOptions({
    queryKey: taskQueueV2Keys.stats(),
    queryFn: () => api.getQueueStats(),
    staleTime: 10 * 1000,
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Enqueues a new task into the queue and invalidates queue stats. */
export function useEnqueue() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Record<string, unknown>) => api.enqueueTask(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: taskQueueV2Keys.all() });
    },
  });
}

/** Claims the next available task from the queue. */
export function useClaim() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data?: Record<string, unknown>) => api.claimTask(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: taskQueueV2Keys.all() });
    },
  });
}

/** Marks a claimed task as completed. */
export function useComplete() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { taskId: string; result?: Record<string, unknown> }) =>
      api.completeTask(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: taskQueueV2Keys.all() });
    },
  });
}

/** Marks a claimed task as failed. */
export function useFailed() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { taskId: string; error?: string }) =>
      api.failTask(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: taskQueueV2Keys.all() });
    },
  });
}

/** Fetches current queue statistics. */
export function useQueueStats() {
  return useQuery(queueStatsOptions());
}
