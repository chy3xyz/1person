import { queryOptions } from "@tanstack/react-query";
import { api } from "../api";

export const trainingKeys = {
  all: (wsId: string) => ["training", wsId] as const,
  courses: (wsId: string, params?: { status?: string }) =>
    [...trainingKeys.all(wsId), "courses", params ?? {}] as const,
  enrollments: (wsId: string, params?: { status?: string }) =>
    [...trainingKeys.all(wsId), "enrollments", params ?? {}] as const,
};

export function courseListOptions(
  wsId: string,
  params?: { status?: string },
) {
  return queryOptions({
    queryKey: trainingKeys.courses(wsId, params),
    queryFn: () => api.listCourses(params),
  });
}

export function enrollmentListOptions(
  wsId: string,
  params?: { status?: string },
) {
  return queryOptions({
    queryKey: trainingKeys.enrollments(wsId, params),
    queryFn: () => api.listEnrollments(params),
  });
}
