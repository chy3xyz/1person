import { useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "../api";
import { trainingKeys } from "./queries";
import { useWorkspaceId } from "../hooks";

export function useEnrollInCourse() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { course_id: string }) => api.enrollInCourse(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: trainingKeys.all(wsId) });
    },
  });
}

export function useCompleteLesson() {
  const qc = useQueryClient();
  const wsId = useWorkspaceId();
  return useMutation({
    mutationFn: (data: { enrollment_id: string; lesson_id: string }) =>
      api.completeLesson(data),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: trainingKeys.all(wsId) });
    },
  });
}
