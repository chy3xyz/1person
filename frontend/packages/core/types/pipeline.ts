export type PipelineRunStatus =
  | "pending"
  | "running"
  | "blocked"
  | "done"
  | "failed";

export type PhaseRunStatus =
  | "pending"
  | "waiting_deps"
  | "running"
  | "awaiting_approval"
  | "done"
  | "failed";

export interface PhaseConfig {
  id: string;
  name: string;
  /** Agent name used for claiming this phase. */
  agent: string;
  /** Phase IDs that must complete before this phase can start. */
  dependsOn: string[];
  timeoutSeconds: number;
  maxRetries: number;
  approvalGate: boolean;
  artifactPattern: string;
}

export interface PhaseRun {
  phaseId: string;
  name: string;
  status: PhaseRunStatus;
  taskIds: string[];
  retries: number;
}

export interface PipelineConfig {
  id: string;
  workspaceId: string;
  name: string;
  description: string;
  phaseCount: number;
  createdAt: string;
  updatedAt: string;
}

export interface PipelineConfigDetail {
  id: string;
  workspaceId: string;
  name: string;
  description: string;
  phases: PhaseConfig[];
  createdAt: string;
  updatedAt: string;
}

export interface PipelineRun {
  id: string;
  pipelineId: string;
  workspaceId: string;
  status: PipelineRunStatus;
  currentPhaseId: string;
  phases: PhaseRun[];
  createdAt: string;
  updatedAt: string;
}
