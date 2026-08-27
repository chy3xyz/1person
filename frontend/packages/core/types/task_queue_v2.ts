// Task queue v2 types — models the distributed agent work queue
// that replaces the original in-process task runner. Tasks are
// durable, retryable, and support priority lanes.

export type TaskPriority = "low" | "normal" | "high" | "critical";

export type TaskStatus =
  | "queued"
  | "claimed"
  | "running"
  | "completed"
  | "failed"
  | "canceled";

export interface Task {
  id: string;
  workspaceId: string;
  /** Agent or pipeline that owns this task. */
  ownerId: string;
  priority: TaskPriority;
  status: TaskStatus;
  /** Short human-readable label for UI lists. */
  label: string;
  /** Arbitrary payload consumed by the worker. */
  input: Record<string, unknown>;
  /** Result produced by the worker (null until completed). */
  output: Record<string, unknown> | null;
  /** Number of times a worker has claimed this task. */
  attempt: number;
  /** Maximum attempts before the task is marked failed. */
  maxAttempts: number;
  /** ISO-8601 timestamp when this task becomes eligible for claiming. */
  notBefore: string;
  claimedBy: string | null;
  claimedAt: string | null;
  completedAt: string | null;
  /** Present only when status is "failed". */
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
}

export interface QueueStats {
  /** How many tasks are waiting to be claimed. */
  queued: number;
  /** How many tasks are currently being processed. */
  running: number;
  /** Tasks that have failed all retries in the current window. */
  dead: number;
  /** Average wait time in milliseconds before first claim. */
  avgWaitMs: number;
  /** Average execution duration in milliseconds. */
  avgDurationMs: number;
}
