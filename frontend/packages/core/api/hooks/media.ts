"use client";

import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

// ---------------------------------------------------------------------------
// Query keys
// ---------------------------------------------------------------------------

export const mediaKeys = {
  all: () => ["media"] as const,
  assets: (params?: Record<string, unknown>) =>
    [...mediaKeys.all(), "assets", params ?? {}] as const,
};

// ---------------------------------------------------------------------------
// Query options (internal)
// ---------------------------------------------------------------------------

export function assetsOptions(params?: Record<string, unknown>) {
  return queryOptions({
    queryKey: mediaKeys.assets(params),
    queryFn: () => api.listAssets(params),
  });
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/** Uploads an asset and invalidates the assets list. */
export function useUploadAsset() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: FormData | Record<string, unknown>) => api.uploadAsset(data),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: mediaKeys.all() });
    },
  });
}

/** Fetches the list of assets, optionally filtered by params. */
export function useAssets(params?: Record<string, unknown>) {
  return useQuery(assetsOptions(params));
}

/** Deletes an asset by id and invalidates the assets list. */
export function useDeleteAsset() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (id: string) => api.deleteAsset(id),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: mediaKeys.all() });
    },
  });
}
