import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const tokenKeys = {
  all: (wsId: string) => ["tokens", wsId] as const,
  balance: (wsId: string) => [...tokenKeys.all(wsId), "balance"] as const,
  transactions: (wsId: string, params?: { page?: number; page_size?: number }) =>
    [...tokenKeys.all(wsId), "transactions", params ?? {}] as const,
};

export function tokenBalanceOptions(wsId: string) {
  return queryOptions({
    queryKey: tokenKeys.balance(wsId),
    queryFn: () => api.getTokenBalance(),
  });
}

export function tokenTransactionsOptions(
  wsId: string,
  params?: { page?: number; page_size?: number },
) {
  return queryOptions({
    queryKey: tokenKeys.transactions(wsId, params),
    queryFn: () => api.listTokenTransactions(params),
  });
}
