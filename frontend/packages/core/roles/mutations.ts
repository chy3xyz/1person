import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { roleKeys } from "./queries";
import { useWorkspaceId } from "../hooks";
import type {
  CreateRoleDefRequest,
  UpdateRoleDefRequest,
  CreateMemberRoleRequest,
  UpdateMemberRoleRequest,
} from "../types";

export function useCreateRoleDef() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: CreateRoleDefRequest) => api.createRoleDef(data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: roleKeys.defs.all(wsId) });
    },
  });
}

export function useUpdateRoleDef() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: ({
      defId,
      data,
    }: {
      defId: string;
      data: UpdateRoleDefRequest;
    }) => api.updateRoleDef(defId, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: roleKeys.defs.all(wsId) });
    },
  });
}

export function useDeleteRoleDef() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (defId: string) => api.deleteRoleDef(defId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: roleKeys.defs.all(wsId) });
    },
  });
}

export function useCreateMemberRole() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: CreateMemberRoleRequest) =>
      api.createMemberRole(data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: roleKeys.members.all(wsId) });
    },
  });
}

export function useUpdateMemberRole() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: ({
      userId,
      data,
    }: {
      userId: string;
      data: UpdateMemberRoleRequest;
    }) => api.updateMemberRole(userId, data),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: roleKeys.members.all(wsId) });
    },
  });
}

export function useDeleteMemberRole() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (userId: string) => api.deleteMemberRole(userId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: roleKeys.members.all(wsId) });
    },
  });
}
