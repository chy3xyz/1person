import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

export const walletKeys = {
  all: () => ["wallet"] as const,
  detail: () => [...walletKeys.all(), "detail"] as const,
  transactions: (params?: { page?: number; page_size?: number }) =>
    [...walletKeys.all(), "transactions", params ?? {}] as const,
};

export function walletDetailOptions() {
  return queryOptions({
    queryKey: walletKeys.detail(),
    queryFn: () => api.getWallet(),
    staleTime: 30 * 1000,
  });
}

export function walletTransactionsOptions(params?: {
  page?: number;
  page_size?: number;
}) {
  return queryOptions({
    queryKey: walletKeys.transactions(params),
    queryFn: () => api.listWalletTransactions(params),
    staleTime: 30 * 1000,
  });
}

export function useWallet() {
  return useQuery(walletDetailOptions());
}

export function useTransactions(
  params?: { page?: number; page_size?: number },
) {
  return useQuery(walletTransactionsOptions(params));
}

export function useDeposit() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { amount: number; payment_method?: string }) =>
      api.depositToWallet(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: walletKeys.all() });
    },
  });
}

export function useWithdraw() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { amount: number; destination: string }) =>
      api.withdrawFromWallet(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: walletKeys.all() });
    },
  });
}
