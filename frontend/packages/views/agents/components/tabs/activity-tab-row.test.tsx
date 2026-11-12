// @vitest-environment jsdom

import { describe, it, expect, vi } from "vitest";
import { screen } from "@testing-library/react";
import type { ReactNode } from "react";
import type { Agent, AgentTask } from "@1person/core/types";
import { renderWithI18n } from "../../../test/i18n";

// The row links to the issue through the shared navigation adapter and
// reaches the api client when a task is cancelled. Neither is what this
// test is about, and both need a provider the test does not stand up.
vi.mock("../../../navigation", () => ({
  AppLink: ({ children, href }: { children: ReactNode; href: string }) => (
    <a href={href}>{children}</a>
  ),
}));
vi.mock("@1person/core/paths", () => ({
  useWorkspacePaths: () => ({ issueDetail: (id: string) => `/issues/${id}` }),
}));
vi.mock("../../../common/task-transcript", () => ({
  TranscriptButton: ({ title }: { title?: string }) => (
    <button type="button">{title ?? "Transcript"}</button>
  ),
}));

import { TaskRow } from "./activity-tab";

const agent: Agent = {
  id: "agent-1",
  workspace_id: "ws-1",
  runtime_id: "runtime-1",
  name: "三源智能体",
  description: "",
  instructions: "",
  avatar_url: null,
  runtime_mode: "local",
  runtime_config: {},
  custom_args: [],
  visibility: "workspace",
  status: "idle",
  max_concurrent_tasks: 1,
  model: "",
  owner_id: "user-1",
  skills: [],
  created_at: "2026-05-28T00:00:00Z",
  updated_at: "2026-05-28T00:00:00Z",
  archived_at: null,
  archived_by: null,
};

function makeTask(overrides: Partial<AgentTask> = {}): AgentTask {
  return {
    id: "task-1",
    agent_id: "agent-1",
    runtime_id: "runtime-1",
    issue_id: "issue-1",
    status: "failed",
    priority: 0,
    dispatched_at: "2026-06-08T08:00:00Z",
    started_at: "2026-06-08T08:00:00Z",
    completed_at: "2026-06-08T08:05:00Z",
    result: null,
    error: null,
    created_at: "2026-06-08T08:00:00Z",
    trigger_summary: "Started from comment",
    failure_reason: "agent_error",
    ...overrides,
  };
}

function renderRow(task: AgentTask) {
  return renderWithI18n(
    <TaskRow task={task} issueMap={new Map()} timeMode="completed" agent={agent} />,
  );
}

describe("TaskRow failure detail", () => {
  it("shows what went wrong, not just that it failed", () => {
    // The coarse label says "Agent error". The daemon's own message says
    // the bound directory does not exist — that is the part the user can
    // act on, and the row used to swallow it entirely.
    renderRow(
      makeTask({
        error:
          "the directory the agent is bound to does not exist on this machine",
      }),
    );

    expect(
      screen.getByText(
        "the directory the agent is bound to does not exist on this machine",
      ),
    ).toBeInTheDocument();
  });

  it("shows the failure reason label next to it", () => {
    renderRow(makeTask({ error: "the repository has no commits yet" }));

    expect(screen.getByText("Agent execution error")).toBeInTheDocument();
    expect(
      screen.getByText("the repository has no commits yet"),
    ).toBeInTheDocument();
  });

  it("keeps the whole message reachable when it is too long for the row", () => {
    const long =
      "the daemon could not create a worktree in the repository the agent is bound to";
    renderRow(makeTask({ error: long }));

    expect(screen.getByTitle(long)).toBeInTheDocument();
  });

  it("shows nothing extra when the task did not fail", () => {
    renderRow(
      makeTask({
        status: "completed",
        failure_reason: undefined,
        error: "some leftover error text",
      }),
    );

    expect(screen.queryByText("some leftover error text")).not.toBeInTheDocument();
  });

  it("shows nothing extra when the failure carried no message", () => {
    renderRow(makeTask({ error: null }));

    expect(screen.getByText("Agent execution error")).toBeInTheDocument();
  });
});
