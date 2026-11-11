// @vitest-environment jsdom

import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import type { Agent } from "@1person/core/types";
import { I18nProvider } from "@1person/core/i18n/react";
import enCommon from "../../../locales/en/common.json";
import enAgents from "../../../locales/en/agents.json";

const TEST_RESOURCES = { en: { common: enCommon, agents: enAgents } };

vi.mock("sonner", () => ({
  toast: {
    error: vi.fn(),
    success: vi.fn(),
  },
}));

import { LocalDirectoryTab } from "./local-directory-tab";

const baseAgent: Agent = {
  id: "agent-1",
  workspace_id: "ws-1",
  runtime_id: "runtime-1",
  name: "Agent",
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

function renderTab(
  overrides: Partial<Agent> = {},
  onSave = vi.fn().mockResolvedValue(undefined),
) {
  const agent = { ...baseAgent, ...overrides };
  const result = render(
    <I18nProvider locale="en" resources={TEST_RESOURCES}>
      <LocalDirectoryTab agent={agent} onSave={onSave} />
    </I18nProvider>,
  );
  return { ...result, onSave };
}

describe("LocalDirectoryTab", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("shows the bound directory and leaves Save disabled until something changes", () => {
    renderTab({ runtime_config: { local_path: "/Users/me/lab" } });

    const input = screen.getByLabelText(/local code directory/i) as HTMLInputElement;
    expect(input.value).toBe("/Users/me/lab");
    expect(screen.getByText("/Users/me/lab")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /save/i })).toBeDisabled();
  });

  it("saves the path into runtime_config", async () => {
    const { onSave } = renderTab();
    const user = userEvent.setup();

    await user.type(screen.getByLabelText(/local code directory/i), "/Users/me/lab");
    await user.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledWith({
        runtime_config: { local_path: "/Users/me/lab" },
      });
    });
  });

  it("keeps the other keys of the runtime config when saving", async () => {
    // `runtime_config` is shared with provider-specific schemas and the
    // update endpoint replaces the whole column — a save that rebuilt it
    // from scratch would drop keys the platform still needs.
    const { onSave } = renderTab({
      runtime_config: { mode: "gateway", gateway: { host: "gw.internal" } },
    });
    const user = userEvent.setup();

    await user.type(screen.getByLabelText(/local code directory/i), "/Users/me/lab");
    await user.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledWith({
        runtime_config: {
          mode: "gateway",
          gateway: { host: "gw.internal" },
          local_path: "/Users/me/lab",
        },
      });
    });
  });

  it("refuses a relative path", async () => {
    // A relative path would be resolved against the daemon's own working
    // directory, which is nowhere the user expects.
    const { onSave } = renderTab();
    const user = userEvent.setup();

    await user.type(screen.getByLabelText(/local code directory/i), "lab");
    expect(screen.getByText(/must be an absolute path/i)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /save/i })).toBeDisabled();

    await user.click(screen.getByRole("button", { name: /save/i }));
    expect(onSave).not.toHaveBeenCalled();
  });

  it("clears the binding through the Clear button", async () => {
    const { onSave } = renderTab({
      runtime_config: { local_path: "/Users/me/lab" },
    });
    const user = userEvent.setup();

    await user.click(screen.getByRole("button", { name: /clear/i }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalledWith({ runtime_config: {} });
    });
  });

  it("reports a failed save instead of pretending it worked", async () => {
    const onSave = vi.fn().mockRejectedValue(new Error("boom"));
    renderTab({}, onSave);
    const user = userEvent.setup();

    await user.type(screen.getByLabelText(/local code directory/i), "/Users/me/lab");
    await user.click(screen.getByRole("button", { name: /save/i }));

    await waitFor(() => {
      expect(onSave).toHaveBeenCalled();
    });
    const { toast } = await import("sonner");
    expect(toast.error).toHaveBeenCalledWith("boom");
  });
});
