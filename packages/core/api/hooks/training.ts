import { queryOptions, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "../index";

export const trainingKeys = {
  all: () => ["training"] as const,
  courses: (params?: { status?: string }) =>
    [...trainingKeys.all(), "courses", params ?? {}] as const,
  enrollments: (params?: { status?: string }) =>
    [...trainingKeys.all(), "enrollments", params ?? {}] as const,
};

export function trainingCoursesOptions(params?: { status?: string }) {
  return queryOptions({
    queryKey: trainingKeys.courses(params),
    queryFn: () => api.listCourses(params),
    staleTime: 2 * 60 * 1000,
  });
}

export function trainingEnrollmentsOptions(params?: { status?: string }) {
  return queryOptions({
    queryKey: trainingKeys.enrollments(params),
    queryFn: () => api.listEnrollments(params),
    staleTime: 60 * 1000,
  });
}

export function useCourses(params?: { status?: string }) {
  return useQuery(trainingCoursesOptions(params));
}

export function useEnrollments(params?: { status?: string }) {
  return useQuery(trainingEnrollmentsOptions(params));
}

export function useEnroll() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { course_id: string }) => api.enrollInCourse(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: trainingKeys.all() });
    },
  });
}

export function useCompleteLesson() {
  const queryClient = useQueryClient();

  return useMutation({
    mutationFn: (data: { enrollment_id: string; lesson_id: string }) =>
      api.completeLesson(data),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: trainingKeys.all() });
    },
  });
}
