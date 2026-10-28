import { describe, expect, it } from "vitest";
import { buildColumns, columnsEqual } from "./drag-utils";
import type { Issue, IssueStatus } from "@1person/core/types";
import type { BoardColumnGroup } from "../components/board-column";

function makeIssue(id: string, status: IssueStatus = "todo"): Issue {
  return {
    id,
    workspace_id: "ws-1",
    number: 1,
    identifier: `MUL-${id}`,
    title: `Issue ${id}`,
    description: null,
    status,
    priority: "none",
    assignee_type: null,
    assignee_id: null,
    creator_type: "member",
    creator_id: "user-1",
    parent_issue_id: null,
    project_id: null,
    position: 0,
    start_date: null,
    due_date: null,
    labels: [],
    metadata: {},
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  };
}

const STATUS_GROUP: BoardColumnGroup = {
  id: "status:todo",
  title: "todo",
  status: "todo",
  createData: { status: "todo" },
};

describe("columnsEqual", () => {
  it("treats two column maps with the same content as equal", () => {
    const a = buildColumns([makeIssue("a"), makeIssue("b")], [STATUS_GROUP], "status");
    const b = buildColumns([makeIssue("a"), makeIssue("b")], [STATUS_GROUP], "status");

    expect(columnsEqual(a, b)).toBe(true);
  });

  it("is false when a column gained an issue", () => {
    const a = buildColumns([makeIssue("a")], [STATUS_GROUP], "status");
    const b = buildColumns([makeIssue("a"), makeIssue("b")], [STATUS_GROUP], "status");

    expect(columnsEqual(a, b)).toBe(false);
  });

  it("is false when the order inside a column changed", () => {
    const a = buildColumns([makeIssue("a"), makeIssue("b")], [STATUS_GROUP], "status");
    const b = buildColumns([makeIssue("b"), makeIssue("a")], [STATUS_GROUP], "status");

    expect(columnsEqual(a, b)).toBe(false);
  });

  it("is false when the set of columns changed", () => {
    const a = buildColumns([makeIssue("a")], [STATUS_GROUP], "status");
    const b = { ...a, "status:done": [] };

    expect(columnsEqual(a, b)).toBe(false);
  });

  it("is false when a column has the same issues in a different order", () => {
    expect(columnsEqual({ c: ["a", "b"] }, { c: ["b", "a"] })).toBe(false);
  });

  it("is true for two empty column maps", () => {
    expect(columnsEqual({}, {})).toBe(true);
  });
});
