"use client";

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "..";
import { useWorkspaceId } from "../../hooks";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

const i18nKeys = {
  all: (wsId: string) => ["i18n", wsId] as const,
  locales: (wsId: string) => [...i18nKeys.all(wsId), "locales"] as const,
  translations: (wsId: string, ns?: string) =>
    [...i18nKeys.all(wsId), "translations", ns ?? ""] as const,
};

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Fetches the list of available locales for the current workspace. */
export function useLocales() {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: i18nKeys.locales(wsId),
    queryFn: () => api.listLocales(),
    staleTime: 5 * 60 * 1000,
  });
}

/** Fetches translations for the current workspace, optionally filtered by namespace. */
export function useTranslations(ns?: string) {
  const wsId = useWorkspaceId();
  return useQuery({
    queryKey: i18nKeys.translations(wsId, ns),
    queryFn: () => api.listTranslations(ns ? { namespace: ns } : undefined),
    staleTime: 2 * 60 * 1000,
  });
}

/** Creates or updates a translation entry and invalidates the translations cache. */
export function useSetTranslation() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: {
      key: string;
      locale: string;
      value: string;
      namespace?: string;
    }) => api.setTranslation(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: i18nKeys.translations(wsId) });
    },
  });
}
