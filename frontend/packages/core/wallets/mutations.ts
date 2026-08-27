import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { walletKeys } from "./queries";
import { useWorkspaceId } from "../hooks";

export function useDepositToWallet() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { amount: number; payment_method?: string }) =>
      api.depositToWallet(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: walletKeys.all(wsId) });
    },
  });
}

export function useWithdrawFromWallet() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { amount: number; destination: string }) =>
      api.withdrawFromWallet(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: walletKeys.all(wsId) });
    },
  });
}
