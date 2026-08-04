"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const analyticsV2Keys = {
  all: () => ["analytics_v2"] as const,
  metrics: (params?: Record<string, unknown>) =>
    [...analyticsV2Keys.all(), "metrics", params ?? {}] as const,
  reports: (params?: Record<string, unknown>) =>
    [...analyticsV2Keys.all(), "reports", params ?? {}] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function queryMetricsOptions(params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: analyticsV2Keys.metrics(params),
    queryFn: () => api.queryMetrics(params),
  });
}

export function reportsOptions(params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: analyticsV2Keys.reports(params),
    queryFn: () => api.listReports(params),
    staleTime: 60 * 1000,
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Tracks a metric event and invalidates related metric queries. */
export function useTrackMetric() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Record<string, unknown>) => api.trackMetric(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: analyticsV2Keys.all() });
    },
  });
}

/** Queries metrics with optional filters. */
export function useQueryMetrics(params?: Record<string, unknown>) {
  return useQuery(queryMetricsOptions(params));
}

/** Fetches analytics reports, optionally filtered by params. */
export function useReports(params?: Record<string, unknown>) {
  return useQuery(reportsOptions(params));
}
