"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const notificationKeys = {
  all: () => ["notifications"] as const,
  templates: () => [...notificationKeys.all(), "templates"] as const,
  logs: (params?: Record<string, unknown>) =>
    [...notificationKeys.all(), "logs", params ?? {}] as const,
  channels: () => [...notificationKeys.all(), "channels"] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function notificationTemplatesOptions() {
  return queryOptions({
    queryKey: notificationKeys.templates(),
    queryFn: () => api.listNotificationTemplates(),
    staleTime: 5 * 60 * 1000,
  });
}

export function notificationLogsOptions(params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: notificationKeys.logs(params),
    queryFn: () => api.listNotificationLogs(params),
  });
}

export function notificationChannelsOptions() {
  return queryOptions({
    queryKey: notificationKeys.channels(),
    queryFn: () => api.listNotificationChannels(),
    staleTime: 5 * 60 * 1000,
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of available notification templates. */
export function useNotificationTemplates() {
  return useQuery(notificationTemplatesOptions());
}

/** Sends a notification and invalidates the logs cache. */
export function useSendNotification() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Record<string, unknown>) => api.sendNotification(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: notificationKeys.logs() });
    },
  });
}

/** Fetches the notification log history, optionally filtered by params. */
export function useNotificationLogs(params?: Record<string, unknown>) {
  return useQuery(notificationLogsOptions(params));
}

/** Fetches the list of configured notification channels. */
export function useNotificationChannels() {
  return useQuery(notificationChannelsOptions());
}
