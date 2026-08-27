import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

export const referralKeys = {
  all: () => ["referral"] as const,
  codes: () => [...referralKeys.all(), "codes"] as const,
  tree: (params?: { depth?: number }) =>
    [...referralKeys.all(), "tree", params ?? {}] as const,
};

export function referralCodesOptions() {
  return queryOptions({
    queryKey: referralKeys.codes(),
    queryFn: () => api.listReferralCodes(),
    staleTime: 2 * 60 * 1000,
  });
}

export function referralTreeOptions(params?: { depth?: number }) {
  return queryOptions({
    queryKey: referralKeys.tree(params),
    queryFn: () => api.getReferralTree(params),
    staleTime: 2 * 60 * 1000,
  });
}

export function useReferralCodes() {
  return useQuery(referralCodesOptions());
}

export function useReferralTree(params?: { depth?: number }) {
  return useQuery(referralTreeOptions(params));
}

export function useTrackReferral() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { code: string; referred_user_id?: string }) =>
      api.trackReferral(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: referralKeys.all() });
    },
  });
}
