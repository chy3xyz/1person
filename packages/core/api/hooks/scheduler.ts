"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const schedulerKeys = {
  all: () => ["scheduler"] as const,
  tasks: (params?: Record<string, unknown>) =>
    [...schedulerKeys.all(), "tasks", params ?? {}] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function scheduledTasksOptions(params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: schedulerKeys.tasks(params),
    queryFn: () => api.listScheduledTasks(params),
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of scheduled tasks, optionally filtered by params. */
export function useScheduledTasks(params?: Record<string, unknown>) {
  return useQuery(scheduledTasksOptions(params));
}

/** Schedules a new task and invalidates the task list. */
export function useScheduleTask() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Record<string, unknown>) => api.scheduleTask(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: schedulerKeys.all() });
    },
  });
}

/** Triggers immediate execution of a scheduled task. */
export function useExecuteNow() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => api.executeTaskNow(id),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: schedulerKeys.all() });
    },
  });
}

/** Cancels a scheduled task and invalidates the task list. */
export function useCancelTask() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => api.cancelScheduledTask(id),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: schedulerKeys.all() });
    },
  });
}
