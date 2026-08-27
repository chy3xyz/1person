"use client";

import {
  queryOptions,
  useMutation,
  useQuery,
  useQueryClient,
} from "@tanstack/react-query";
import { api } from "../index";

export interface RoleDef {
  id: string;
  workspace_id: string;
  name: string;
  description: string | null;
  position: number;
  created_at: string;
  updated_at: string;
}

export interface CreateRoleDefRequest {
  name: string;
  description?: string;
  position?: number;
}

export interface UpdateRoleDefRequest {
  name?: string;
  description?: string;
  position?: number;
}

export interface MemberRole {
  id: string;
  workspace_id: string;
  user_id: string;
  role_def_id: string;
  created_at: string;
  updated_at: string;
}

export interface CreateMemberRoleRequest {
  user_id: string;
  role_def_id: string;
}

export interface UpdateMemberRoleRequest {
  role_def_id: string;
}

export const roleKeys = {
  all: (wsId: string) => ["roles", wsId] as const,
  defs: {
    all: (wsId: string) => [...roleKeys.all(wsId), "defs"] as const,
    list: (wsId: string) =>
      [...roleKeys.defs.all(wsId), "list"] as const,
    detail: (wsId: string, defId: string) =>
      [...roleKeys.defs.all(wsId), "detail", defId] as const,
  },
  members: {
    all: (wsId: string) => [...roleKeys.all(wsId), "members"] as const,
    list: (wsId: string) =>
      [...roleKeys.members.all(wsId), "list"] as const,
    detail: (wsId: string, userId: string) =>
      [...roleKeys.members.all(wsId), "detail", userId] as const,
    downline: (wsId: string, userId: string) =>
      [...roleKeys.members.all(wsId), "downline", userId] as const,
    upline: (wsId: string, userId: string) =>
      [...roleKeys.members.all(wsId), "upline", userId] as const,
  },
};

export function roleDefListOptions(wsId: string) {
  return queryOptions({
    queryKey: roleKeys.defs.list(wsId),
    queryFn: () => api.listRoleDefs(),
    enabled: !!wsId,
  });
}

export function roleDefDetailOptions(wsId: string, defId: string) {
  return queryOptions({
    queryKey: roleKeys.defs.detail(wsId, defId),
    queryFn: () => api.getRoleDef(defId),
    enabled: !!wsId && !!defId,
  });
}

export function memberRoleListOptions(wsId: string) {
  return queryOptions({
    queryKey: roleKeys.members.list(wsId),
    queryFn: () => api.listMemberRoles(),
    enabled: !!wsId,
  });
}

export function memberRoleDetailOptions(wsId: string, userId: string) {
  return queryOptions({
    queryKey: roleKeys.members.detail(wsId, userId),
    queryFn: () => api.getMemberRole(userId),
    enabled: !!wsId && !!userId,
  });
}

export function downlineOptions(wsId: string, userId: string) {
  return queryOptions({
    queryKey: roleKeys.members.downline(wsId, userId),
    queryFn: () => api.getDownline(userId),
    enabled: !!wsId && !!userId,
  });
}

export function uplineOptions(wsId: string, userId: string) {
  return queryOptions({
    queryKey: roleKeys.members.upline(wsId, userId),
    queryFn: () => api.getUpline(userId),
    enabled: !!wsId && !!userId,
  });
}

export function useRoleDefs(wsId: string) {
  return useQuery(roleDefListOptions(wsId));
}

export function useMemberRoles(wsId: string) {
  return useQuery(memberRoleListOptions(wsId));
}

export function useDownline(wsId: string, userId: string) {
  return useQuery(downlineOptions(wsId, userId));
}

export function useUpline(wsId: string, userId: string) {
  return useQuery(uplineOptions(wsId, userId));
}

export function useCreateRoleDef() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ data }: { wsId: string; data: CreateRoleDefRequest }) =>
      api.createRoleDef(data),
    onSuccess: (_result, { wsId }) => {
      queryClient.invalidateQueries({
        queryKey: roleKeys.defs.all(wsId),
      });
    },
  });
}

export function useUpdateRoleDef() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      defId,
      data,
    }: {
      wsId: string;
      defId: string;
      data: UpdateRoleDefRequest;
    }) => api.updateRoleDef(defId, data),
    onSuccess: (_result, { wsId }) => {
      queryClient.invalidateQueries({
        queryKey: roleKeys.defs.all(wsId),
      });
    },
  });
}

export function useDeleteRoleDef() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ defId }: { wsId: string; defId: string }) =>
      api.deleteRoleDef(defId),
    onSuccess: (_result, { wsId }) => {
      queryClient.invalidateQueries({
        queryKey: roleKeys.defs.all(wsId),
      });
    },
  });
}

export function useCreateMemberRole() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      data,
    }: {
      wsId: string;
      data: CreateMemberRoleRequest;
    }) => api.createMemberRole(data),
    onSuccess: (_result, { wsId }) => {
      queryClient.invalidateQueries({
        queryKey: roleKeys.members.all(wsId),
      });
    },
  });
}

export function useUpdateMemberRole() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({
      userId,
      data,
    }: {
      wsId: string;
      userId: string;
      data: UpdateMemberRoleRequest;
    }) => api.updateMemberRole(userId, data),
    onSuccess: (_result, { wsId }) => {
      queryClient.invalidateQueries({
        queryKey: roleKeys.members.all(wsId),
      });
    },
  });
}

export function useDeleteMemberRole() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ userId }: { wsId: string; userId: string }) =>
      api.deleteMemberRole(userId),
    onSuccess: (_result, { wsId }) => {
      queryClient.invalidateQueries({
        queryKey: roleKeys.members.all(wsId),
      });
    },
  });
}
