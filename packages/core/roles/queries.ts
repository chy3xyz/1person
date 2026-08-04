import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const roleKeys = {
  all: (wsId: string) => ["roles", wsId] as const,

  defs: {
    all: (wsId: string) => [...roleKeys.all(wsId), "defs"] as const,
    list: (wsId: string) => [...roleKeys.defs.all(wsId), "list"] as const,
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
    queryFn: async () => {
      const res: any = await api.listRoleDefs();
      return (res?.defs ?? []) as import("../types").RoleDef[];
    },
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
