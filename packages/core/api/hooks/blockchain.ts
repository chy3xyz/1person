"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const blockchainKeys = {
  all: () => ["blockchain"] as const,
  chains: () => [...blockchainKeys.all(), "chains"] as const,
  wallets: () => [...blockchainKeys.all(), "wallets"] as const,
  txs: (params?: Record<string, unknown>) =>
    [...blockchainKeys.all(), "txs", params ?? {}] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function chainsOptions() {
  return queryOptions({
    queryKey: blockchainKeys.chains(),
    queryFn: () => api.listChains(),
    staleTime: 10 * 60 * 1000,
  });
}

export function walletsOptions() {
  return queryOptions({
    queryKey: blockchainKeys.wallets(),
    queryFn: () => api.listWallets(),
    staleTime: 30 * 1000,
  });
}

export function txsOptions(params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: blockchainKeys.txs(params),
    queryFn: () => api.listTransactions(params),
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of supported blockchain networks. */
export function useChains() {
  return useQuery(chainsOptions());
}

/** Fetches the list of connected wallets. */
export function useWallets() {
  return useQuery(walletsOptions());
}

/** Sends a blockchain transaction and invalidates the tx list. */
export function useSendTx() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: Record<string, unknown>) => api.sendTransaction(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: blockchainKeys.all() });
    },
  });
}

/** Fetches the list of transactions, optionally filtered by params. */
export function useTxs(params?: Record<string, unknown>) {
  return useQuery(txsOptions(params));
}
