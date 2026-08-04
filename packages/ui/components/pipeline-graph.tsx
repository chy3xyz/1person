"use client"

import { cn } from "@1person/ui/lib/utils";

// ── Types ──────────────────────────────────────────────

export interface PhaseNode {
  id: string;
  name: string;
  status: "pending" | "waiting_deps" | "running" | "awaiting_approval" | "done" | "failed";
  dependsOn: string[];
}

export interface PipelineGraphProps {
  phases: PhaseNode[];
  currentPhaseId?: string;
  className?: string;
  onPhaseClick?: (phaseId: string) => void;
}

// ── Status helpers ─────────────────────────────────────

const STATUS_STYLES: Record<PhaseNode["status"], string> = {
  pending: "border-gray-300 bg-gray-50 text-gray-400 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-500",
  waiting_deps: "border-amber-300 bg-amber-50 text-amber-600 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-400",
  running: "border-blue-400 bg-blue-50 text-blue-700 animate-pulse dark:border-blue-700 dark:bg-blue-950 dark:text-blue-300",
  awaiting_approval: "border-purple-400 bg-purple-50 text-purple-700 dark:border-purple-700 dark:bg-purple-950 dark:text-purple-300",
  done: "border-green-400 bg-green-50 text-green-700 dark:border-green-700 dark:bg-green-950 dark:text-green-300",
  failed: "border-red-400 bg-red-50 text-red-700 dark:border-red-700 dark:bg-red-950 dark:text-red-300",
};

const STATUS_LABELS: Record<PhaseNode["status"], string> = {
  pending: "Pending",
  waiting_deps: "Waiting",
  running: "Running",
  awaiting_approval: "Approval",
  done: "Done",
  failed: "Failed",
};

const STATUS_DOTS: Record<PhaseNode["status"], string> = {
  pending: "○",
  waiting_deps: "◐",
  running: "●",
  awaiting_approval: "◆",
  done: "✓",
  failed: "✗",
};

// ── Component ──────────────────────────────────────────

export function PipelineGraph({
  phases,
  currentPhaseId,
  className,
  onPhaseClick,
}: PipelineGraphProps) {
  if (!phases.length) {
    return (
      <div className={cn("p-8 text-center text-muted-foreground text-sm", className)}>
        No phases configured
      </div>
    );
  }

  return (
    <div className={cn("flex flex-wrap items-center gap-2 p-4", className)}>
      {phases.map((phase, i) => (
        <div key={phase.id} className="flex items-center gap-2">
          {/* Phase card */}
          <button
            type="button"
            onClick={() => onPhaseClick?.(phase.id)}
            className={cn(
              "flex flex-col items-center gap-1 rounded-lg border-2 px-4 py-3 min-w-[120px]",
              "transition-all hover:scale-105 cursor-pointer",
              phase.id === currentPhaseId && "ring-2 ring-ring ring-offset-2",
              STATUS_STYLES[phase.status],
            )}
          >
            <span className="text-lg font-mono">{STATUS_DOTS[phase.status]}</span>
            <span className="text-sm font-semibold">{phase.name}</span>
            <span className="text-xs opacity-70">{STATUS_LABELS[phase.status]}</span>
          </button>
          {/* Arrow between phases */}
          {i < phases.length - 1 && (
            <div className="flex items-center text-muted-foreground">
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M5 12h14M13 5l7 7-7 7" />
              </svg>
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

// ── Compact variant for small spaces ───────────────────

export function PipelineGraphCompact({
  phases,
  currentPhaseId,
  className,
}: Omit<PipelineGraphProps, "onPhaseClick">) {
  if (!phases.length) return null;
  return (
    <div className={cn("flex items-center gap-1", className)}>
      {phases.map((phase, i) => (
        <div key={phase.id} className="flex items-center gap-1">
          <div
            className={cn(
              "h-2.5 w-2.5 rounded-full",
              phase.status === "done" && "bg-green-500",
              phase.status === "running" && "bg-blue-500 animate-pulse",
              phase.status === "failed" && "bg-red-500",
              phase.status === "awaiting_approval" && "bg-purple-500",
              phase.status === "waiting_deps" && "bg-amber-500",
              (phase.status === "pending") && "bg-gray-300 dark:bg-gray-600",
              phase.id === currentPhaseId && "ring-2 ring-ring ring-offset-1",
            )}
            title={`${phase.name}: ${STATUS_LABELS[phase.status]}`}
          />
          {i < phases.length - 1 && (
            <div className="h-px w-3 bg-gray-300 dark:bg-gray-600" />
          )}
        </div>
      ))}
    </div>
  );
}
