import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

export const commissionKeys = {
  all: () => ["commission"] as const,
  rules: () => [...commissionKeys.all(), "rules"] as const,
};

export function commissionRulesOptions() {
  return queryOptions({
    queryKey: commissionKeys.rules(),
    queryFn: () => api.getCommissionRules(),
    staleTime: 5 * 60 * 1000,
  });
}

export function useCommissionRules() {
  return useQuery(commissionRulesOptions());
}

export function useCalculateCommission() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { amount: number; code?: string }) =>
      api.calculateCommission(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: commissionKeys.all() });
    },
  });
}
