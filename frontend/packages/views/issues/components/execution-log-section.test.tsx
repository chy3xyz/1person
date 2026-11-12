// @vitest-environment jsdom

import { cleanup, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AgentTask } from "@1person/core/types";
import { renderWithI18n } from "../../test/i18n";

const mockState = vi.hoisted(() => ({
  taskMessagesOptions: vi.fn(),
}));

vi.mock("@1person/core/chat/queries", () => ({
  taskMessagesOptions: mockState.taskMessagesOptions,
}));

vi.mock("../../common/actor-avatar", () => ({
  ActorAvatar: () => <span data-testid="actor-avatar" />,
}));

vi.mock("../../common/task-transcript", () => ({
  TranscriptButton: ({ title }: { title?: string }) => (
    <button type="button">{title ?? "Transcript"}</button>
  ),
}));

vi.mock("./terminate-task-confirm-dialog", () => ({
  TerminateTaskConfirmDialog: () => null,
}));

import { ActiveTaskRow, PastRow } from "./execution-log-section";

function makeTask(overrides: Partial<AgentTask> = {}): AgentTask {
  return {
    id: "task-1",
    agent_id: "agent-1",
    runtime_id: "runtime-1",
    issue_id: "issue-1",
    status: "running",
    priority: 0,
    dispatched_at: null,
    started_at: "2026-06-08T08:00:00Z",
    completed_at: null,
    result: null,
    error: null,
    created_at: "2026-06-08T08:00:00Z",
    trigger_summary: "Started from comment",
    ...overrides,
  };
}

beforeEach(() => {
  cleanup();
  vi.clearAllMocks();
  vi.useFakeTimers();
  vi.setSystemTime(new Date("2026-06-08T08:05:04Z"));
});

afterEach(() => {
  vi.useRealTimers();
});

describe("ActiveTaskRow", () => {
  it("renders running status as elapsed time only", () => {
    renderWithI18n(<ActiveTaskRow task={makeTask()} issueId="issue-1" />);

    expect(screen.getByText("5m 04s")).toBeInTheDocument();
    expect(screen.queryByText(/events?/i)).not.toBeInTheDocument();
    expect(screen.getByText("Started from comment")).toBeInTheDocument();
    expect(screen.getByText("View transcript")).toBeInTheDocument();
    expect(mockState.taskMessagesOptions).not.toHaveBeenCalled();
  });
});

describe("PastRow", () => {
  it("shows what went wrong, not just that it failed", () => {
    // A failed issue run leaves no comment on the issue — the server only
    // reports the failure to a chat session. This row is therefore the only
    // place the user learns that the bound directory does not exist, and
    // the coarse "Agent execution error" label used to be all it said.
    renderWithI18n(
      <PastRow
        task={makeTask({
          status: "failed",
          completed_at: "2026-06-08T08:05:00Z",
          failure_reason: "agent_error",
          error:
            "the directory the agent is bound to does not exist on this machine",
        })}
        issueId="issue-1"
      />,
    );

    expect(
      screen.getByText(
        "the directory the agent is bound to does not exist on this machine",
      ),
    ).toBeInTheDocument();
    expect(screen.getByText("Agent execution error")).toBeInTheDocument();
  });

  it("keeps the whole message reachable when it is too long for the row", () => {
    const long =
      "the daemon could not create a worktree in the repository the agent is bound to";
    renderWithI18n(
      <PastRow
        task={makeTask({
          status: "failed",
          completed_at: "2026-06-08T08:05:00Z",
          failure_reason: "agent_error",
          error: long,
        })}
        issueId="issue-1"
      />,
    );

    expect(screen.getByTitle(long)).toBeInTheDocument();
  });

  it("shows nothing extra on a run that did not fail", () => {
    renderWithI18n(
      <PastRow
        task={makeTask({
          status: "completed",
          completed_at: "2026-06-08T08:05:00Z",
          failure_reason: undefined,
          error: "some leftover error text",
        })}
        issueId="issue-1"
      />,
    );

    expect(
      screen.queryByText("some leftover error text"),
    ).not.toBeInTheDocument();
  });
});
