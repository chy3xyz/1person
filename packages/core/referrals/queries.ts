import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const referralKeys = {
  all: (wsId: string) => ["referrals", wsId] as const,
  codes: (wsId: string) => [...referralKeys.all(wsId), "codes"] as const,
  tree: (wsId: string, params?: { depth?: number }) =>
    [...referralKeys.all(wsId), "tree", params ?? {}] as const,
};

export function referralCodesOptions(wsId: string) {
  return queryOptions({
    queryKey: referralKeys.codes(wsId),
    queryFn: () => api.listReferralCodes(),
  });
}

export function referralTreeOptions(
  wsId: string,
  params?: { depth?: number },
) {
  return queryOptions({
    queryKey: referralKeys.tree(wsId, params),
    queryFn: () => api.getReferralTree(params),
  });
}
