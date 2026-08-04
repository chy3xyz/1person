import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { commissionKeys } from "./queries";
import { useWorkspaceId } from "../hooks";

export function useCalculateCommission() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { amount: number; code?: string }) =>
      api.calculateCommission(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: commissionKeys.all(wsId) });
    },
  });
}
