import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const walletKeys = {
  all: (wsId: string) => ["wallets", wsId] as const,
  detail: (wsId: string) => [...walletKeys.all(wsId), "detail"] as const,
  transactions: (wsId: string, params?: { page?: number; page_size?: number }) =>
    [...walletKeys.all(wsId), "transactions", params ?? {}] as const,
};

export function walletOptions(wsId: string) {
  return queryOptions({
    queryKey: walletKeys.detail(wsId),
    queryFn: () => api.getWallet(),
  });
}

export function walletTransactionsOptions(
  wsId: string,
  params?: { page?: number; page_size?: number },
) {
  return queryOptions({
    queryKey: walletKeys.transactions(wsId, params),
    queryFn: () => api.listWalletTransactions(params),
  });
}
