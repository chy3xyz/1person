import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { tokenKeys } from "./queries";
import { useWorkspaceId } from "../hooks";

export function useEarnTokens() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { amount: number; source: string; description?: string }) =>
      api.earnTokens(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: tokenKeys.all(wsId) });
    },
  });
}

export function useSpendTokens() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { amount: number; purpose: string; description?: string }) =>
      api.spendTokens(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: tokenKeys.all(wsId) });
    },
  });
}
