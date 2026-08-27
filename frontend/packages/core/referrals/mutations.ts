import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { referralKeys } from "./queries";
import { useWorkspaceId } from "../hooks";

export function useTrackReferral() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { code: string; referred_user_id?: string }) =>
      api.trackReferral(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: referralKeys.all(wsId) });
    },
  });
}
