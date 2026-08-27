export type EnrollmentStatus =
  | "enrolled"
  | "in_progress"
  | "completed"
  | "failed";

export interface Course {
  id: string;
  workspaceId: string;
  name: string;
  createdAt: string;
}

export interface Lesson {
  id: string;
  courseId: string;
  title: string;
  content: string;
  quiz: string | null;
}

export interface Enrollment {
  userId: string;
  courseId: string;
  status: EnrollmentStatus;
  completedLessons: string[];
  certificateId: string | null;
  createdAt: string;
}
