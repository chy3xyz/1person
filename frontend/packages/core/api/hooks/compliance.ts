"use client";

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "..";
import { useWorkspaceId } from "../../hooks";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

const complianceKeys = {
  all: (wsId: string) => ["compliance", wsId] as const,
  auditRules: (wsId: string) =>
    [...complianceKeys.all(wsId), "audit-rules"] as const,
  auditLogs: (wsId: string, params?: { page?: number; page_size?: number }) =>
    [...complianceKeys.all(wsId), "audit-logs", params ?? {}] as const,
};

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of audit rules for the current workspace. */
export function useAuditRules() {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: complianceKeys.auditRules(wsId),
    queryFn: () => api.listAuditRules(),
    staleTime: 5 * 60 * 1000,
  });
}

/** Triggers an audit run for the specified rules and invalidates cached logs. */
export function useRunAudit() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data?: { rule_ids?: string[] }) =>
      api.runAudit(data ?? {}),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: complianceKeys.all(wsId) });
    },
  });
}

/** Fetches audit log entries for the current workspace with optional pagination. */
export function useAuditLogs(params?: { page?: number; page_size?: number }) {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: complianceKeys.auditLogs(wsId, params),
    queryFn: () => api.listAuditLogs(params),
  });
}
