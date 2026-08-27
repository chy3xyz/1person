import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

export const tokenKeys = {
  all: () => ["token-economy"] as const,
  balance: () => [...tokenKeys.all(), "balance"] as const,
  transactions: (params?: { page?: number; page_size?: number }) =>
    [...tokenKeys.all(), "transactions", params ?? {}] as const,
};

export function tokenBalanceOptions() {
  return queryOptions({
    queryKey: tokenKeys.balance(),
    queryFn: () => api.getTokenBalance(),
    staleTime: 30 * 1000,
  });
}

export function tokenTransactionsOptions(params?: {
  page?: number;
  page_size?: number;
}) {
  return queryOptions({
    queryKey: tokenKeys.transactions(params),
    queryFn: () => api.listTokenTransactions(params),
    staleTime: 30 * 1000,
  });
}

export function useBalance() {
  return useQuery(tokenBalanceOptions());
}

export function useTransactions(
  params?: { page?: number; page_size?: number },
) {
  return useQuery(tokenTransactionsOptions(params));
}

export function useEarn() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: {
      amount: number;
      source: string;
      description?: string;
    }) => api.earnTokens(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: tokenKeys.all() });
    },
  });
}

export function useSpend() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: {
      amount: number;
      purpose: string;
      description?: string;
    }) => api.spendTokens(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: tokenKeys.all() });
    },
  });
}
