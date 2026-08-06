"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const connectorKeys = {
  all: () => ["connectors"] as const,
  list: () => [...connectorKeys.all(), "list"] as const,
  logs: (id: string, params?: Record<string, unknown>) =>
    [...connectorKeys.all(), "logs", id, params ?? {}] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function connectorsOptions() {
  return queryOptions({
    queryKey: connectorKeys.list(),
    queryFn: () => api.listConnectors(),
    staleTime: 5 * 60 * 1000,
  });
}

export function connectorLogsOptions(id: string, params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: connectorKeys.logs(id, params),
    queryFn: () => api.listConnectorLogs(id, params),
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of available connectors. */
export function useConnectors() {
  return useQuery(connectorsOptions());
}

/** Calls a connector and invalidates related caches. */
export function useCallConnector() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { connectorId: string; payload: Record<string, unknown> }) =>
      api.callConnector(data),
    onSettled: (_data, _err, vars) => {
      queryClient.invalidateQueries({ queryKey: connectorKeys.logs(vars.connectorId) });
      queryClient.invalidateQueries({ queryKey: connectorKeys.all() });
    },
  });
}

/** Fetches logs for a specific connector, optionally filtered by params. */
export function useConnectorLogs(id: string, params?: Record<string, unknown>) {
  return useQuery({
    ...connectorLogsOptions(id, params),
    enabled: !!id,
  });
}
