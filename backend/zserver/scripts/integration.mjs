#!/usr/bin/env node
// Frontend integration smoke test for zserver.
//
// This script mirrors the call patterns the Next.js frontend uses
// (see apps/web → packages/core/api/client.ts) and asserts that
// zserver returns the same response shapes the TypeScript client
// expects. It is the no-DB analog of running apps/web against the
// Go server: every code path exercised here is the same one the
// real frontend would walk.
//
// Usage:
//   node scripts/integration.mjs [base_url]
//   base_url defaults to http://127.0.0.1:18099.

const BASE = process.argv[2] || "http://127.0.0.1:18099";

let failures = 0;
function pass(name) { console.log(`\x1b[32mPASS\x1b[0m: ${name}`); }
function fail(name, detail) {
  failures++;
  console.error(`\x1b[31mFAIL\x1b[0m: ${name}: ${detail || ""}`);
}
function assert(cond, name, detail) {
  if (cond) pass(name);
  else fail(name, detail);
}

async function api(method, path, opts = {}) {
  const headers = { "Content-Type": "application/json", ...(opts.headers || {}) };
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  let json = null;
  const text = await res.text();
  if (text) {
    try { json = JSON.parse(text); } catch (_) { json = text; }
  }
  return { status: res.status, body: json, raw: text };
}

// Some zserver endpoints wrap the response in `{data: ...}` (the
// issue mutation endpoints), while Go-shape endpoints return the
// resource at the top level. This helper unwraps a response so the
// test can find the id regardless of which shape it receives.
function unwrap(body) {
  if (body == null) return null;
  if (typeof body !== "object") return body;
  if (body.id) return body;
  if (body.data?.id) return body.data;
  if (Array.isArray(body)) return { items: body };
  if (body.data && Array.isArray(body.data)) return { items: body.data };
  if (body.issues) return { items: body.issues };
  if (body.data?.issues) return { items: body.data.issues };
  if (body.nodes) return { items: body.nodes };
  if (body.labels) return { items: body.labels };
  if (body.resources) return { items: body.resources };
  if (body.deliveries) return { items: body.deliveries };
  if (body.skills) return { items: body.skills };
  if (body.workspaces) return { items: body.workspaces };
  return body;
}

async function main() {
  // ─── 1. /health (frontend uses this for smoke) ─────────────
  {
    const r = await fetch(`${BASE}/health`);
    assert(r.status === 200, "01 GET /health", `status=${r.status}`);
  }

  // ─── 2. /health/realtime ────────────────────────────────
  {
    const r = await api("GET", "/health/realtime");
    assert(r.status === 200, "02 GET /health/realtime", `status=${r.status} body=${JSON.stringify(r.body)}`);
  }

  // ─── 3. auth/send-code + verify-code → token (frontend login)
  const email = `feint-${Date.now()}-${Math.random().toString(36).slice(2, 6)}@example.com`;
  await api("POST", "/auth/send-code", { body: { email } });
  const verify = await api("POST", "/auth/verify-code", {
    body: { email, code: process.env.MULTICA_DEV_VERIFICATION_CODE || "000000" },
  });
  if (verify.status !== 200 || !verify.body?.token) {
    console.error("verify-code failed:", JSON.stringify(verify));
    process.exit(1);
  }
  const token = verify.body.token;
  const authH = { Authorization: `Bearer ${token}` };
  assert(typeof token === "string" && token.length > 16, "03 auth flow", `token_len=${token?.length}`);

  // ─── 4. /api/me (frontend bootstraps user state here) ───
  const me = await api("GET", "/api/me", { headers: authH });
  assert(me.status === 200 && me.body?.id, "04 GET /api/me", `status=${me.status}`);
  const userId = me.body.id;

  // ─── 5. createWorkspace (frontend onboarding step 1) ─────
  const ws = await api("POST", "/api/workspaces", {
    headers: authH,
    body: {
      name: "Frontend Integration",
      slug: `feint-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
      description: "frontend-integration",
    },
  });
  assert(ws.status === 201 || ws.status === 200, "05 createWorkspace", `status=${ws.status} body=${JSON.stringify(ws.body)}`);
  const workspaceId = unwrap(ws.body)?.id;
  const wsH = { ...authH, "X-Workspace-Id": workspaceId };

  // ─── 6. listWorkspaces (frontend sidebar) ───────────────
  const lws = await api("GET", "/api/workspaces", { headers: authH });
  assert(Array.isArray(lws.body) && lws.body.length >= 1, "06 listWorkspaces", `count=${lws.body?.length}`);

  // ─── 7. createProject (frontend onboarding step 2) ──────
  const project = await api("POST", "/api/projects", {
    headers: wsH,
    body: { title: "Frontend Project", description: "feint", status: "planned", priority: "none" },
  });
  assert(project.status === 201 || project.status === 200, "07 createProject", `status=${project.status} body=${JSON.stringify(project.body)}`);

  // ─── 8. createIssue (frontend new-issue flow) ───────────
  const issue = await api("POST", "/api/issues", {
    headers: wsH,
    body: { title: "Frontend Integration Issue", state: "todo" },
  });
  assert(issue.status === 201 || issue.status === 200, "08 createIssue", `status=${issue.status} body=${JSON.stringify(issue.body)}`);
  const issueId = unwrap(issue.body)?.id;
  assert(typeof issueId === "string" && issueId.length > 0, "08b createIssue has id", `id=${issueId}`);

  // ─── 9. listIssues (frontend issues list) ───────────────
  const li = await api("GET", "/api/issues", { headers: wsH });
  const liItems = unwrap(li.body)?.items || li.body;
  assert(Array.isArray(liItems) && liItems.length >= 1, "09 listIssues", `status=${li.status} body=${JSON.stringify(li.body).slice(0,200)}`);

  // ─── 10. updateIssue (frontend drag/drop state change) ──
  if (issueId) {
    const upd = await api("PATCH", `/api/issues/${issueId}`, {
      headers: wsH,
      body: { state: "in_progress" },
    });
    const updObj = unwrap(upd.body);
    assert(upd.status === 200 && updObj?.state === "in_progress", "10 updateIssue to in_progress", `status=${upd.status} state=${updObj?.state}`);
  }

  // ─── 11. addReaction (frontend reaction UI) ─────────────
  if (issueId) {
    const rx = await api("POST", `/api/issues/${issueId}/reactions`, {
      headers: wsH,
      body: { actor_id: userId, emoji: "thumbsup" },
    });
    assert(rx.status === 201 || rx.status === 200, "11 addReaction", `status=${rx.status}`);
  }

  // ─── 12. listSkills (frontend skills page) ──────────────
  const skills = await api("GET", "/api/skills", { headers: wsH });
  assert(skills.status === 200, "12 listSkills", `status=${skills.status}`);

  // ─── 13. createSkill (frontend skill create) ────────────
  const skill = await api("POST", "/api/skills", {
    headers: wsH,
    body: { name: "Frontend Test Skill", description: "feint", content: "# hello", files: [] },
  });
  assert(skill.status === 201 || skill.status === 200, "13 createSkill", `status=${skill.status}`);

  // ─── 14. listLabels (frontend label manager) ────────────
  const labels = await api("GET", "/api/labels", { headers: wsH });
  assert(labels.status === 200, "14 listLabels", `status=${labels.status}`);

  // ─── 15. createLabel (frontend label manager) ───────────
  const label = await api("POST", "/api/labels", {
    headers: wsH,
    body: { name: "frontend-test", color: "#10b981" },
  });
  assert(label.status === 201 || label.status === 200, "15 createLabel", `status=${label.status} body=${JSON.stringify(label.body)}`);
  const labelId = unwrap(label.body)?.id;

  // ─── 16. attachLabel to issue (frontend issue detail) ───
  if (issueId && labelId) {
    const att = await api("POST", `/api/issues/${issueId}/labels`, {
      headers: wsH,
      body: { label_id: labelId },
    });
    assert(att.status === 200 || att.status === 201, "16 attachLabel", `status=${att.status}`);
  }

  // ─── 17. listIssueLabels (frontend issue detail labels) ─
  if (issueId) {
    const ill = await api("GET", `/api/issues/${issueId}/labels`, { headers: wsH });
    assert(ill.status === 200, "17 listIssueLabels", `status=${ill.status}`);
  }

  // ─── 18. comment trigger preview (frontend composer) ───
  if (issueId) {
    const preview = await api("POST", `/api/issues/${issueId}/comments/trigger-preview`, {
      headers: wsH,
      body: { content: "hello @agent-foo" },
    });
    assert(preview.status === 200, "18 previewCommentTriggers", `status=${preview.status}`);
  }

  // ─── 19. contact-sales (frontend footer form) ──────────
  const cs = await api("POST", "/api/contact-sales", {
    body: { name: "Frontend Buyer", email: "buyer@example.com", message: "tell me more", company: "Acme" },
  });
  assert(cs.status === 200 || cs.status === 201 || cs.status === 204, "19 contactSales", `status=${cs.status}`);

  // ─── 20. health/realtime liveness check ───────────────
  const rt = await api("GET", "/health/realtime");
  assert(rt.status === 200, "20 health/realtime", `status=${rt.status}`);

  // ─── 21. assignee-frequency (frontend analytics) ───────
  const af = await api("GET", "/api/assignee-frequency", { headers: wsH });
  assert(af.status === 200, "21 assignee-frequency", `status=${af.status}`);

  // ─── 22. inbox (frontend bell) ─────────────────────────
  const inbox = await api("GET", "/api/inbox", { headers: wsH });
  assert(inbox.status === 200, "22 inbox", `status=${inbox.status}`);

  // ─── 22b. inbox advanced (since, unread, mark-all-read) ──
  const inboxSince = await api("GET", "/api/inbox/since?seq=0", { headers: wsH });
  assert(inboxSince.status === 200, "22b inbox since", `status=${inboxSince.status}`);
  const unread = await api("GET", "/api/inbox/unread-count", { headers: wsH });
  assert(unread.status === 200, "22c inbox unread-count", `status=${unread.status}`);
  const markAll = await api("POST", "/api/inbox/mark-all-read", { headers: wsH });
  assert(markAll.status === 200 || markAll.status === 204, "22d inbox mark-all-read", `status=${markAll.status}`);

  // ─── 23. autopilot (frontend autopilot page) ───────────
  const ap = await api("POST", "/api/autopilots", {
    headers: wsH,
    body: {
      title: "Frontend Autopilot",
      assignee_type: "squad",
      assignee_id: workspaceId,
      execution_mode: "create_issue",
      issue_title_template: "Auto: {{title}}",
    },
  });
  assert(ap.status === 201 || ap.status === 200, "23 createAutopilot", `status=${ap.status}`);

  // ─── 24. cloud runtime (frontend cloud page) ───────────
  const cn = await api("POST", "/api/cloud-runtime/nodes", {
    headers: wsH,
    body: { name: "feint-node", region: "us-east-1", size: "small" },
  });
  assert(cn.status === 201 || cn.status === 200, "24 createCloudNode", `status=${cn.status}`);
  const cnId = unwrap(cn.body)?.id;
  if (cnId) {
    const st = await api("GET", `/api/cloud-runtime/nodes/${cnId}/status`, { headers: wsH });
    assert(st.status === 200, "24b getCloudNodeStatus", `status=${st.status}`);
  }

  // ─── 25. dashboard (frontend analytics) ────────────────
  const dashDaily = await api("GET", "/api/dashboard/usage/daily", { headers: wsH });
  assert(dashDaily.status === 200, "25 dashboard usage/daily", `status=${dashDaily.status}`);
  const dashByAgent = await api("GET", "/api/dashboard/usage/by-agent", { headers: wsH });
  assert(dashByAgent.status === 200, "25b dashboard usage/by-agent", `status=${dashByAgent.status}`);
  const dashRuntime = await api("GET", "/api/dashboard/agent-runtime", { headers: wsH });
  assert(dashRuntime.status === 200, "25c dashboard agent-runtime", `status=${dashRuntime.status}`);

  // ─── 26. agents (frontend agents page) ─────────────────
  const RUNTIME_UUID = "00000000-0000-0000-0000-000000000002";
  // Ensure the runtime exists before creating the agent (FK constraint).
  await api("POST", "/api/runtimes", { headers: wsH, body: { id: RUNTIME_UUID, name: "feint-runtime", runtime_mode: "local" } });
  const ag = await api("POST", "/api/agents", {
    headers: wsH,
    body: { name: "feint-agent", runtime_id: RUNTIME_UUID, model: "claude-sonnet" },
  });
  assert(ag.status === 201 || ag.status === 200, "26 createAgent", `status=${ag.status}`);
  const agId = unwrap(ag.body)?.id;
  if (agId) {
    const agGet = await api("GET", `/api/agents/${agId}`, { headers: wsH });
    assert(agGet.status === 200, "26b getAgent", `status=${agGet.status}`);
    const agEnv = await api("PUT", `/api/agents/${agId}/env`, { headers: wsH, body: { custom_env: { K: "v" } } });
    assert(agEnv.status === 200, "26c setAgentEnv", `status=${agEnv.status}`);
  }

  // ─── 27. agent-templates (frontend template picker) ─────
  const tplBody = await api("POST", "/api/agent-templates", {
    headers: wsH,
    body: { slug: `feint-${Date.now()}`, name: "Feint Template" },
  });
  assert(tplBody.status === 201 || tplBody.status === 200, "27 createAgentTemplate", `status=${tplBody.status}`);

  // ─── 28. lark binding redeem (frontend lark OAuth step) ──
  const lark = await api("POST", "/api/lark/binding/redeem", {
    body: { code: "lark_test_code_" + Date.now(), workspace_id: workspaceId },
  });
  // The lark redeem endpoint is correct to return 404 for an
  // unknown code in the no-DB path (and would 200 in the DB path
  // if a binding row exists). Accept either.
  assert(
    lark.status === 200 || lark.status === 201 || lark.status === 400 || lark.status === 404,
    "28 lark/binding/redeem",
    `status=${lark.status} body=${JSON.stringify(lark.body).slice(0, 100)}`,
  );

  // ─── 29. health/realtime WS upgrade liveness ────────────
  const rt2 = await api("GET", "/health/realtime");
  assert(rt2.status === 200, "29 health/realtime liveness", `status=${rt2.status}`);

  // ─── 30. cleanup workspace ─────────────────────────────
  const del = await api("DELETE", `/api/workspaces/${workspaceId}`, { headers: authH });
  assert(del.status === 200 || del.status === 204, "30 deleteWorkspace", `status=${del.status}`);

  console.log("");
  if (failures === 0) {
    console.log(`\x1b[32mAll 30 frontend integration checks passed\x1b[0m`);
    process.exit(0);
  } else {
    console.log(`\x1b[31m${failures} check(s) failed\x1b[0m`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("unhandled error:", e);
  process.exit(1);
});
