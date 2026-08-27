// Types for the task scheduler module. Scheduled tasks are one-shot or
// recurring work items that run agent pipelines on a cron-like cadence.

export type ScheduledTaskStatus =
  | "active"
  | "paused"
  | "completed"
  | "failed";

export interface ScheduledTask {
  id: string;
  workspaceId: string;
  name: string;
  /** Cron expression (e.g. "0 9 * * 1-5"). */
  cronExpression: string;
  /** ID of the pipeline config executed on each tick. */
  pipelineId: string;
  status: ScheduledTaskStatus;
  /** Number of times this task has fired successfully. */
  runCount: number;
  lastRunAt: string | null;
  nextRunAt: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface ScheduleTaskRequest {
  name: string;
  cronExpression: string;
  pipelineId: string;
  /** Optional key-value overrides injected into the pipeline run context. */
  context?: Record<string, unknown>;
}
