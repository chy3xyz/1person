"use client";

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "..";
import { useWorkspaceId } from "../../hooks";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

const communityOpsKeys = {
  all: (wsId: string) => ["community-ops", wsId] as const,
  groups: (wsId: string, params?: { status?: string }) =>
    [...communityOpsKeys.all(wsId), "groups", params ?? {}] as const,
  groupMembers: (wsId: string, groupId: string) =>
    [...communityOpsKeys.all(wsId), "group-members", groupId] as const,
  announcements: (
    wsId: string,
    params?: { page?: number; page_size?: number },
  ) => [...communityOpsKeys.all(wsId), "announcements", params ?? {}] as const,
  dailyDigest: (wsId: string) =>
    [...communityOpsKeys.all(wsId), "daily-digest"] as const,
};

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of community groups for the current workspace. */
export function useGroups(params?: { status?: string }) {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: communityOpsKeys.groups(wsId, params),
    queryFn: () => api.listGroups(params),
    staleTime: 60 * 1000,
  });
}

/** Fetches the members of a specific community group. */
export function useGroupMembers(groupId: string) {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: communityOpsKeys.groupMembers(wsId, groupId),
    queryFn: () => api.listGroupMembers(groupId),
    enabled: !!groupId,
  });
}

/** Fetches announcements for the current workspace with optional pagination. */
export function useAnnouncements(params?: {
  page?: number;
  page_size?: number;
}) {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: communityOpsKeys.announcements(wsId, params),
    queryFn: () => api.listAnnouncements(params),
    staleTime: 60 * 1000,
  });
}

/** Creates an announcement and invalidates the announcements list cache. */
export function useCreateAnnouncement() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: {
      title: string;
      content: string;
      group_ids?: string[];
    }) => api.createAnnouncement(data),
    onSettled: () => {
      qc.invalidateQueries({
        queryKey: communityOpsKeys.announcements(wsId),
      });
    },
  });
}

/** Fetches the daily digest for the current workspace. */
export function useDailyDigest() {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: communityOpsKeys.dailyDigest(wsId),
    queryFn: () => api.getDailyDigest(),
    staleTime: 60 * 1000,
  });
}
