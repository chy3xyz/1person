import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const commissionKeys = {
  all: (wsId: string) => ["commissions", wsId] as const,
  rules: (wsId: string) => [...commissionKeys.all(wsId), "rules"] as const,
};

export function commissionRulesOptions(wsId: string) {
  return queryOptions({
    queryKey: commissionKeys.rules(wsId),
    queryFn: () => api.getCommissionRules(),
  });
}
