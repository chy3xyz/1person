# Track F – Generic Product-Domain CRUD Stubs

Concrete request/response shapes extracted from `server/internal/handler/*.go` and `server/migrations/*.sql` for the Track F generic CRUD stub layer.

> **Scope:** This is a shape reference, not an implementation spec. It covers list/get/create/update/delete plus the most closely related sub-resource endpoints. Search, batch, import, webhook, daemon state-machine, and dashboard aggregation endpoints are noted where they deviate from pure CRUD.

---

## Common Conventions

| Concept | Go representation | Zig stub representation |
|---|---|---|
| UUIDs | `string` (JSON) | `[]const u8` |
| Timestamps | `string` RFC3339 | `[]const u8` |
| Optional scalar | pointer (`*string`, `*int32`) | `?T` |
| Optional JSON object | `any`, `json.RawMessage`, `map[string]any` | `std.json.Value` |
| Enumerated strings | `string` with handler validation | `[]const u8` (validated) |
| Lists | slices (`[]T`) | `[]T` |
| Empty-array safety | handlers emit `[]T{}` rather than `nil` | stubs should emit `[]` |

Typical status codes: `200 OK`, `201 Created`, `204 No Content`, `400 Bad Request`, `403 Forbidden`, `404 Not Found`, `409 Conflict`, `413 Payload Too Large`, `415 Unsupported Media Type`, `500 Internal Server Error`, `502/503` for upstream or storage failures.

---

## Issues

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/issues` | List issues with filters |
| GET | `/api/issues/search` | Full-text search |
| POST | `/api/issues` | Create issue |
| GET | `/api/issues/:id` | Get issue |
| PATCH | `/api/issues/:id` | Update issue |
| DELETE | `/api/issues/:id` | Delete issue |
| POST | `/api/issues/batch-update` | Batch update |
| POST | `/api/issues/:id/quick-create` | Agent/squad quick create |
| POST | `/api/issues/:id/rerun` | Rerun assigned agent |

### Go structs

```go
type IssueResponse struct {
    ID            string                  `json:"id"`
    WorkspaceID   string                  `json:"workspace_id"`
    Number        int32                   `json:"number"`
    Identifier    string                  `json:"identifier"`
    Title         string                  `json:"title"`
    Description   *string                 `json:"description"`
    Status        string                  `json:"status"`
    Priority      string                  `json:"priority"`
    AssigneeType  *string                 `json:"assignee_type"`
    AssigneeID    *string                 `json:"assignee_id"`
    CreatorType   string                  `json:"creator_type"`
    CreatorID     string                  `json:"creator_id"`
    ParentIssueID *string                 `json:"parent_issue_id"`
    ProjectID     *string                 `json:"project_id"`
    Position      float64                 `json:"position"`
    StartDate     *string                 `json:"start_date"`
    DueDate       *string                 `json:"due_date"`
    CreatedAt     string                  `json:"created_at"`
    UpdatedAt     string                  `json:"updated_at"`
    Metadata      map[string]any          `json:"metadata"`
    Reactions     []IssueReactionResponse `json:"reactions,omitempty"`
    Attachments   []AttachmentResponse    `json:"attachments,omitempty"`
    Labels        *[]LabelResponse        `json:"labels,omitempty"`
}

type CreateIssueRequest struct {
    Title          string   `json:"title"`
    Description    *string  `json:"description"`
    Status         string   `json:"status"`
    Priority       string   `json:"priority"`
    AssigneeType   *string  `json:"assignee_type"`
    AssigneeID     *string  `json:"assignee_id"`
    ParentIssueID  *string  `json:"parent_issue_id"`
    ProjectID      *string  `json:"project_id"`
    StartDate      *string  `json:"start_date"`
    DueDate        *string  `json:"due_date"`
    AttachmentIDs  []string `json:"attachment_ids,omitempty"`
    OriginType     *string  `json:"origin_type,omitempty"`
    OriginID       *string  `json:"origin_id,omitempty"`
    AllowDuplicate bool     `json:"allow_duplicate,omitempty"`
}

type UpdateIssueRequest struct {
    Title         *string  `json:"title"`
    Description   *string  `json:"description"`
    Status        *string  `json:"status"`
    Priority      *string  `json:"priority"`
    AssigneeType  *string  `json:"assignee_type"`
    AssigneeID    *string  `json:"assignee_id"`
    Position      *float64 `json:"position"`
    StartDate     *string  `json:"start_date"`
    DueDate       *string  `json:"due_date"`
    ParentIssueID *string  `json:"parent_issue_id"`
    ProjectID     *string  `json:"project_id"`
    AttachmentIDs []string `json:"attachment_ids"`
}
```

### Validation / status codes

- `title` is required on create.
- Default `status="todo"`; default `priority="none"`.
- `status` ∈ `{backlog, todo, in_progress, in_review, done, blocked, cancelled}`.
- `priority` ∈ `{urgent, high, medium, low, none}`.
- `assignee_type` ∈ `{member, agent, squad}`.
- Duplicate detection may return `409` with code `active_duplicate_issue`.
- Common errors: `"workspace_id is required"`, `"title is required"`, `"failed to create issue"`, `"issue not found"`.

### Suggested Zig shapes

```zig
pub const Issue = struct {
    id: []const u8,
    workspace_id: []const u8,
    number: i32,
    identifier: []const u8,
    title: []const u8,
    description: ?[]const u8,
    status: []const u8,
    priority: []const u8,
    assignee_type: ?[]const u8,
    assignee_id: ?[]const u8,
    creator_type: []const u8,
    creator_id: []const u8,
    parent_issue_id: ?[]const u8,
    project_id: ?[]const u8,
    position: f64,
    start_date: ?[]const u8,
    due_date: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    metadata: std.json.Value,
    reactions: []IssueReaction,
    attachments: []Attachment,
    labels: ?[]Label,
};

pub const CreateIssue = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    assignee_type: ?[]const u8 = null,
    assignee_id: ?[]const u8 = null,
    parent_issue_id: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    start_date: ?[]const u8 = null,
    due_date: ?[]const u8 = null,
    attachment_ids: []const []const u8 = &.{},
};
```

### SQL snippets

```sql
CREATE TABLE issue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT,
    status TEXT NOT NULL DEFAULT 'todo',
    priority TEXT NOT NULL DEFAULT 'none',
    assignee_type TEXT CHECK (assignee_type IN ('member','agent','squad')),
    assignee_id UUID,
    creator_type TEXT NOT NULL CHECK (creator_type IN ('member','agent')),
    creator_id UUID NOT NULL,
    parent_issue_id UUID REFERENCES issue(id) ON DELETE SET NULL,
    project_id UUID REFERENCES project(id) ON DELETE SET NULL,
    position FLOAT NOT NULL DEFAULT 0,
    start_date DATE,
    due_date DATE,
    metadata JSONB NOT NULL DEFAULT '{}',
    origin_type TEXT,
    origin_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

| Route | Guidance |
|---|---|
| `GET /api/issues` | Real query required. |
| `GET /api/issues/:id` | Real query required. |
| `POST /api/issues` | Real query required. |
| `PATCH /api/issues/:id` | Real query required. |
| `DELETE /api/issues/:id` | Real query required. |
| `GET /api/issues/search` | Can return `[]` initially. |
| `POST /api/issues/batch-update` | Can return 501 in first stub. |
| `POST /api/issues/:id/quick-create` | Async task spawn; safe to return empty `task_id` stub. |
| `POST /api/issues/:id/rerun` | Needs task service; omit or stub. |

---

## Projects

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/projects` | List projects |
| POST | `/api/projects` | Create project |
| GET | `/api/projects/:id` | Get project |
| PATCH | `/api/projects/:id` | Update project |
| DELETE | `/api/projects/:id` | Delete project |
| GET/POST | `/api/projects/:id/resources` | Project resources |

### Go structs

```go
type ProjectResponse struct {
    ID            string  `json:"id"`
    WorkspaceID   string  `json:"workspace_id"`
    Title         string  `json:"title"`
    Description   *string `json:"description"`
    Icon          *string `json:"icon"`
    Status        string  `json:"status"`
    Priority      string  `json:"priority"`
    LeadType      *string `json:"lead_type"`
    LeadID        *string `json:"lead_id"`
    CreatedAt     string  `json:"created_at"`
    UpdatedAt     string  `json:"updated_at"`
    IssueCount    int64   `json:"issue_count"`
    DoneCount     int64   `json:"done_count"`
    ResourceCount int64   `json:"resource_count"`
}

type CreateProjectRequest struct {
    Title       string                                `json:"title"`
    Description *string                               `json:"description"`
    Icon        *string                               `json:"icon"`
    Status      string                                `json:"status"`
    Priority    string                                `json:"priority"`
    LeadType    *string                               `json:"lead_type"`
    LeadID      *string                               `json:"lead_id"`
    Resources   []CreateProjectResourceRequestPayload `json:"resources,omitempty"`
}

type CreateProjectResourceRequestPayload struct {
    ResourceType string          `json:"resource_type"`
    ResourceRef  json.RawMessage `json:"resource_ref"`
    Label        *string         `json:"label"`
    Position     *int32          `json:"position"`
}

type UpdateProjectRequest struct {
    Title       *string `json:"title"`
    Description *string `json:"description"`
    Icon        *string `json:"icon"`
    Status      *string `json:"status"`
    Priority    *string `json:"priority"`
    LeadType    *string `json:"lead_type"`
    LeadID      *string `json:"lead_id"`
}
```

### Validation

- `title` required.
- `status` ∈ `{planned, in_progress, paused, completed, cancelled}`.
- `priority` ∈ `{urgent, high, medium, low, none}`.
- `lead_type` ∈ `{member, agent}`.

### Suggested Zig shapes

```zig
pub const Project = struct {
    id: []const u8,
    workspace_id: []const u8,
    title: []const u8,
    description: ?[]const u8,
    icon: ?[]const u8,
    status: []const u8,
    priority: []const u8,
    lead_type: ?[]const u8,
    lead_id: ?[]const u8,
    created_at: []const u8,
    updated_at: []const u8,
    issue_count: i64,
    done_count: i64,
    resource_count: i64,
};

pub const CreateProject = struct {
    title: []const u8,
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    status: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    lead_type: ?[]const u8 = null,
    lead_id: ?[]const u8 = null,
    resources: []const ProjectResourcePayload = &.{},
};
```

### SQL snippets

```sql
CREATE TABLE project (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    description TEXT,
    icon TEXT,
    status TEXT NOT NULL DEFAULT 'planned',
    priority TEXT NOT NULL DEFAULT 'none',
    lead_type TEXT CHECK (lead_type IN ('member','agent')),
    lead_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

- Real CRUD for `/api/projects` is required for the issue sidebar.
- `/api/projects/:id/resources` can return `[]` in Track F.

---

## Labels

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/labels` | List labels |
| POST | `/api/labels` | Create label |
| GET | `/api/labels/:id` | Get label |
| PATCH | `/api/labels/:id` | Update label |
| DELETE | `/api/labels/:id` | Delete label |
| POST | `/api/issues/:id/labels` | Attach label to issue |
| DELETE | `/api/issues/:id/labels/:labelId` | Detach label |

### Go structs

```go
type LabelResponse struct {
    ID          string `json:"id"`
    WorkspaceID string `json:"workspace_id"`
    Name        string `json:"name"`
    Color       string `json:"color"`
    CreatedAt   string `json:"created_at"`
    UpdatedAt   string `json:"updated_at"`
}

type CreateLabelRequest struct {
    Name  string `json:"name"`
    Color string `json:"color"`
}

type UpdateLabelRequest struct {
    Name  *string `json:"name"`
    Color *string `json:"color"`
}

type AttachLabelRequest struct {
    LabelID string `json:"label_id"`
}
```

### Validation

- `name` required, max 32 chars.
- `color` must match `^#?[0-9a-fA-F]{6}$`; normalized to `#rrggbb`.
- Duplicate name returns `409`.

### SQL snippets

```sql
CREATE TABLE issue_label (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    color TEXT NOT NULL,
    UNIQUE (workspace_id, name)
);

CREATE TABLE issue_to_label (
    issue_id UUID NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    label_id UUID NOT NULL REFERENCES issue_label(id) ON DELETE CASCADE,
    PRIMARY KEY (issue_id, label_id)
);
```

### Stub vs real queries

- Full label CRUD + issue attach/detach should be real for the issue UI.

---

## Squads

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/squads` | List squads |
| POST | `/api/squads` | Create squad |
| GET | `/api/squads/:id` | Get squad |
| PATCH | `/api/squads/:id` | Update squad |
| DELETE | `/api/squads/:id` | Archive squad |
| GET | `/api/squads/:id/members` | List members |
| POST | `/api/squads/:id/members` | Add member |
| DELETE | `/api/squads/:id/members` | Remove member |
| GET | `/api/squads/:id/members/status` | Member presence |

### Go structs

```go
type SquadResponse struct {
    ID            string                       `json:"id"`
    WorkspaceID   string                       `json:"workspace_id"`
    Name          string                       `json:"name"`
    Description   string                       `json:"description"`
    Instructions  string                       `json:"instructions"`
    AvatarURL     *string                      `json:"avatar_url"`
    LeaderID      string                       `json:"leader_id"`
    CreatorID     string                       `json:"creator_id"`
    CreatedAt     string                       `json:"created_at"`
    UpdatedAt     string                       `json:"updated_at"`
    ArchivedAt    *string                      `json:"archived_at"`
    ArchivedBy    *string                      `json:"archived_by"`
    MemberCount   int                          `json:"member_count"`
    MemberPreview []SquadMemberPreviewResponse `json:"member_preview"`
}

type SquadMemberPreviewResponse struct {
    MemberType string `json:"member_type"`
    MemberID   string `json:"member_id"`
    Role       string `json:"role"`
}

type SquadMemberResponse struct {
    ID         string `json:"id"`
    SquadID    string `json:"squad_id"`
    MemberType string `json:"member_type"`
    MemberID   string `json:"member_id"`
    Role       string `json:"role"`
    CreatedAt  string `json:"created_at"`
}
```

Create/update/add/remove use inline structs:

```go
type _CreateSquadRequest struct {
    Name        string  `json:"name"`
    Description string  `json:"description"`
    LeaderID    string  `json:"leader_id"`
    AvatarURL   *string `json:"avatar_url"`
}

type _UpdateSquadRequest struct {
    Name         *string `json:"name"`
    Description  *string `json:"description"`
    Instructions *string `json:"instructions"`
    LeaderID     *string `json:"leader_id"`
    AvatarURL    *string `json:"avatar_url"`
}

type _AddSquadMemberRequest struct {
    MemberType string `json:"member_type"` // "agent" | "member"
    MemberID   string `json:"member_id"`
    Role       string `json:"role"`
}

type _RemoveSquadMemberRequest struct {
    MemberType string `json:"member_type"`
    MemberID   string `json:"member_id"`
}
```

### Validation

- `name` required.
- `leader_id` must be an agent in the workspace.
- Cannot remove the squad leader.

### SQL snippets

```sql
CREATE TABLE squad (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    instructions TEXT NOT NULL DEFAULT '',
    leader_id UUID NOT NULL REFERENCES agent(id) ON DELETE RESTRICT,
    creator_id UUID NOT NULL,
    archived_at TIMESTAMPTZ,
    archived_by UUID REFERENCES "user"(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, name)
);

CREATE TABLE squad_member (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    squad_id UUID NOT NULL REFERENCES squad(id) ON DELETE CASCADE,
    member_type TEXT NOT NULL CHECK (member_type IN ('agent','member')),
    member_id UUID NOT NULL,
    role TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (squad_id, member_type, member_id)
);
```

### Stub vs real queries

- Squad CRUD + member management should be real.
- `/member-status` presence derivation can return static `"offline"` statuses in a stub.

---

## Agents

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/agents` | List agents |
| POST | `/api/agents` | Create agent |
| GET | `/api/agents/:id` | Get agent |
| PATCH | `/api/agents/:id` | Update agent |
| DELETE | `/api/agents/:id` | Archive agent |
| POST | `/api/agents/:id/restore` | Restore agent |
| POST | `/api/agents/:id/cancel-tasks` | Cancel all tasks |
| GET/PUT | `/api/agents/:id/env` | Secret env |

### Go structs

```go
type AgentResponse struct {
    ID                 string              `json:"id"`
    WorkspaceID        string              `json:"workspace_id"`
    RuntimeID          string              `json:"runtime_id"`
    Name               string              `json:"name"`
    Description        string              `json:"description"`
    Instructions       string              `json:"instructions"`
    AvatarURL          *string             `json:"avatar_url"`
    RuntimeMode        string              `json:"runtime_mode"`
    RuntimeConfig      any                 `json:"runtime_config"`
    CustomArgs         []string            `json:"custom_args"`
    McpConfig          json.RawMessage     `json:"mcp_config"`
    HasCustomEnv       bool                `json:"has_custom_env"`
    CustomEnvKeyCount  int                 `json:"custom_env_key_count"`
    McpConfigRedacted  bool                `json:"mcp_config_redacted"`
    Visibility         string              `json:"visibility"`
    Status             string              `json:"status"`
    MaxConcurrentTasks int32               `json:"max_concurrent_tasks"`
    Model              string              `json:"model"`
    ThinkingLevel      string              `json:"thinking_level"`
    OwnerID            *string             `json:"owner_id"`
    Skills             []AgentSkillSummary `json:"skills"`
    CreatedAt          string              `json:"created_at"`
    UpdatedAt          string              `json:"updated_at"`
    ArchivedAt         *string             `json:"archived_at"`
    ArchivedBy         *string             `json:"archived_by"`
}

type AgentSkillSummary struct {
    ID          string `json:"id"`
    Name        string `json:"name"`
    Description string `json:"description"`
}

type CreateAgentRequest struct {
    Name               string            `json:"name"`
    Description        string            `json:"description"`
    Instructions       string            `json:"instructions"`
    AvatarURL          *string           `json:"avatar_url"`
    RuntimeID          string            `json:"runtime_id"`
    RuntimeConfig      any               `json:"runtime_config"`
    CustomEnv          map[string]string `json:"custom_env"`
    CustomArgs         []string          `json:"custom_args"`
    McpConfig          json.RawMessage   `json:"mcp_config"`
    Visibility         string            `json:"visibility"`
    MaxConcurrentTasks int32             `json:"max_concurrent_tasks"`
    Model              string            `json:"model"`
    ThinkingLevel      string            `json:"thinking_level"`
    Template           string            `json:"template"`
}

type UpdateAgentRequest struct {
    Name               *string          `json:"name"`
    Description        *string          `json:"description"`
    Instructions       *string          `json:"instructions"`
    AvatarURL          *string          `json:"avatar_url"`
    RuntimeID          *string          `json:"runtime_id"`
    RuntimeConfig      any              `json:"runtime_config"`
    CustomArgs         *[]string        `json:"custom_args"`
    McpConfig          *json.RawMessage `json:"mcp_config"`
    Visibility         *string          `json:"visibility"`
    Status             *string          `json:"status"`
    MaxConcurrentTasks *int32           `json:"max_concurrent_tasks"`
    Model              *string          `json:"model"`
    ThinkingLevel      *string          `json:"thinking_level"`
}
```

### Validation

- `name` required.
- `runtime_id` must exist in workspace.
- `visibility` ∈ `{workspace, private}`.
- `status` ∈ `{idle, working, blocked, error, offline}`.
- `runtime_mode` ∈ `{local, cloud}`.
- `custom_env` is not updatable via `PATCH /api/agents/:id`.

### SQL snippets

```sql
CREATE TABLE agent (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    instructions TEXT NOT NULL DEFAULT '',
    avatar_url TEXT,
    runtime_id UUID REFERENCES agent_runtime(id),
    runtime_mode TEXT NOT NULL CHECK (runtime_mode IN ('local','cloud')),
    runtime_config JSONB NOT NULL DEFAULT '{}',
    custom_args JSONB NOT NULL DEFAULT '[]',
    custom_env JSONB NOT NULL DEFAULT '{}',
    mcp_config JSONB,
    visibility TEXT NOT NULL DEFAULT 'private',
    status TEXT NOT NULL DEFAULT 'offline',
    max_concurrent_tasks INT NOT NULL DEFAULT 6,
    model TEXT,
    thinking_level TEXT,
    owner_id UUID REFERENCES "user"(id),
    archived_at TIMESTAMPTZ,
    archived_by UUID REFERENCES "user"(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, name)
);
```

### Stub vs real queries

- Agent CRUD should be real.
- Archive/restore affect task state; keep real or stub with no-op.
- `/api/agents/:id/env` can return `403` or empty in Track F.

---

## Skills

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/skills` | List skill summaries |
| GET | `/api/skills/search` | Search ClawHub |
| POST | `/api/skills` | Create skill |
| GET | `/api/skills/:id` | Get skill with files |
| PATCH | `/api/skills/:id` | Update skill |
| DELETE | `/api/skills/:id` | Delete skill |
| POST | `/api/skills/import` | Import from URL |
| PUT | `/api/agents/:id/skills` | Set agent skills |
| POST | `/api/agents/:id/skills` | Add agent skills |

### Go structs

```go
type SkillResponse struct {
    ID          string  `json:"id"`
    WorkspaceID string  `json:"workspace_id"`
    Name        string  `json:"name"`
    Description string  `json:"description"`
    Content     string  `json:"content"`
    Config      any     `json:"config"`
    CreatedBy   *string `json:"created_by"`
    CreatedAt   string  `json:"created_at"`
    UpdatedAt   string  `json:"updated_at"`
}

type SkillSummaryResponse struct {
    ID          string  `json:"id"`
    WorkspaceID string  `json:"workspace_id"`
    Name        string  `json:"name"`
    Description string  `json:"description"`
    Config      any     `json:"config"`
    CreatedBy   *string `json:"created_by"`
    CreatedAt   string  `json:"created_at"`
    UpdatedAt   string  `json:"updated_at"`
}

type SkillWithFilesResponse struct {
    SkillResponse
    Files []SkillFileResponse `json:"files"`
}

type SkillFileResponse struct {
    ID        string `json:"id"`
    SkillID   string `json:"skill_id"`
    Path      string `json:"path"`
    Content   string `json:"content"`
    CreatedAt string `json:"created_at"`
    UpdatedAt string `json:"updated_at"`
}

type CreateSkillRequest struct {
    Name        string                   `json:"name"`
    Description string                   `json:"description"`
    Content     string                   `json:"content"`
    Config      any                      `json:"config"`
    Files       []CreateSkillFileRequest `json:"files,omitempty"`
}

type CreateSkillFileRequest struct {
    Path    string `json:"path"`
    Content string `json:"content"`
}

type UpdateSkillRequest struct {
    Name        *string                  `json:"name"`
    Description *string                  `json:"description"`
    Content     *string                  `json:"content"`
    Config      any                      `json:"config"`
    Files       []CreateSkillFileRequest `json:"files,omitempty"`
}

type SetAgentSkillsRequest struct {
    SkillIDs []string `json:"skill_ids"`
}

type ImportSkillRequest struct {
    URL        string `json:"url"`
    OnConflict string `json:"on_conflict,omitempty"` // fail | overwrite | rename | skip
}
```

### Validation

- `name` required.
- File paths must be relative and not traverse (`..`).
- Unique name per workspace (`409` on conflict).

### SQL snippets

```sql
CREATE TABLE skill (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    content TEXT NOT NULL DEFAULT '',
    config JSONB NOT NULL DEFAULT '{}',
    created_by UUID REFERENCES "user"(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (workspace_id, name)
);

CREATE TABLE skill_file (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    skill_id UUID NOT NULL REFERENCES skill(id) ON DELETE CASCADE,
    path TEXT NOT NULL,
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (skill_id, path)
);

CREATE TABLE agent_skill (
    agent_id UUID NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
    skill_id UUID NOT NULL REFERENCES skill(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (agent_id, skill_id)
);
```

### Stub vs real queries

- Local skill CRUD should be real.
- `/api/skills/search` and `/api/skills/import` hit upstream ClawHub/GitHub; safe to return empty or 502 stub.

---

## Autopilots

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/autopilots` | List autopilots |
| POST | `/api/autopilots` | Create autopilot |
| GET | `/api/autopilots/:id` | Get autopilot |
| PATCH | `/api/autopilots/:id` | Update autopilot |
| DELETE | `/api/autopilots/:id` | Delete autopilot |
| GET | `/api/autopilots/:id/triggers` | List triggers |
| POST | `/api/autopilots/:id/triggers` | Create trigger |
| PATCH | `/api/autopilots/:id/triggers/:triggerId` | Update trigger |
| DELETE | `/api/autopilots/:id/triggers/:triggerId` | Delete trigger |
| PUT | `/api/autopilots/:id/triggers/:triggerId/signing-secret` | Set signing secret |
| GET | `/api/autopilots/:id/runs` | List runs |
| GET | `/api/autopilots/:id/runs/:runId` | Get run |
| POST | `/api/autopilots/:id/trigger` | Manual trigger |

### Go structs

```go
type AutopilotResponse struct {
    ID                 string  `json:"id"`
    WorkspaceID        string  `json:"workspace_id"`
    Title              string  `json:"title"`
    Description        *string `json:"description"`
    ProjectID          *string `json:"project_id"`
    AssigneeType       string  `json:"assignee_type"`
    AssigneeID         string  `json:"assignee_id"`
    Status             string  `json:"status"`
    ExecutionMode      string  `json:"execution_mode"`
    IssueTitleTemplate *string `json:"issue_title_template"`
    CreatedByType      string  `json:"created_by_type"`
    CreatedByID        string  `json:"created_by_id"`
    LastRunAt          *string `json:"last_run_at"`
    CreatedAt          string  `json:"created_at"`
    UpdatedAt          string  `json:"updated_at"`
}

type CreateAutopilotRequest struct {
    Title              string  `json:"title"`
    Description        *string `json:"description"`
    ProjectID          *string `json:"project_id"`
    AssigneeType       *string `json:"assignee_type"`
    AssigneeID         string  `json:"assignee_id"`
    ExecutionMode      string  `json:"execution_mode"`
    IssueTitleTemplate *string `json:"issue_title_template"`
}

type UpdateAutopilotRequest struct {
    Title              *string `json:"title"`
    Description        *string `json:"description"`
    ProjectID          *string `json:"project_id"`
    AssigneeType       *string `json:"assignee_type"`
    AssigneeID         *string `json:"assignee_id"`
    Status             *string `json:"status"`
    ExecutionMode      *string `json:"execution_mode"`
    IssueTitleTemplate *string `json:"issue_title_template"`
}

type AutopilotTriggerResponse struct {
    ID                string               `json:"id"`
    AutopilotID       string               `json:"autopilot_id"`
    Kind              string               `json:"kind"`
    Enabled           bool                 `json:"enabled"`
    CronExpression    *string              `json:"cron_expression"`
    Timezone          *string              `json:"timezone"`
    NextRunAt         *string              `json:"next_run_at"`
    WebhookToken      *string              `json:"webhook_token"`
    WebhookPath       *string              `json:"webhook_path"`
    WebhookURL        *string              `json:"webhook_url"`
    Provider          *string              `json:"provider"`
    HasSigningSecret  bool                 `json:"has_signing_secret"`
    SigningSecretHint *string              `json:"signing_secret_hint"`
    Label             *string              `json:"label"`
    LastFiredAt       *string              `json:"last_fired_at"`
    CreatedAt         string               `json:"created_at"`
    UpdatedAt         string               `json:"updated_at"`
    EventFilters      []WebhookEventFilter `json:"event_filters,omitempty"`
}

type CreateAutopilotTriggerRequest struct {
    Kind           string               `json:"kind"`
    CronExpression *string              `json:"cron_expression"`
    Timezone       *string              `json:"timezone"`
    Label          *string              `json:"label"`
    Provider       *string              `json:"provider"`
    EventFilters   []WebhookEventFilter `json:"event_filters,omitempty"`
}

type UpdateAutopilotTriggerRequest struct {
    Enabled        *bool                `json:"enabled"`
    CronExpression *string              `json:"cron_expression"`
    Timezone       *string              `json:"timezone"`
    Label          *string              `json:"label"`
    EventFilters   *[]WebhookEventFilter `json:"event_filters,omitempty"`
}

type SetSigningSecretRequest struct {
    SigningSecret string `json:"signing_secret"`
}

type AutopilotRunResponse struct {
    ID             string  `json:"id"`
    AutopilotID    string  `json:"autopilot_id"`
    TriggerID      *string `json:"trigger_id"`
    Source         string  `json:"source"`
    Status         string  `json:"status"`
    IssueID        *string `json:"issue_id"`
    TaskID         *string `json:"task_id"`
    TriggeredAt    string  `json:"triggered_at"`
    CompletedAt    *string `json:"completed_at"`
    FailureReason  *string `json:"failure_reason"`
    TriggerPayload any     `json:"trigger_payload"`
    Result         any     `json:"result"`
    CreatedAt      string  `json:"created_at"`
}
```

### Validation

- `title` required.
- `status` ∈ `{active, paused, archived}`.
- `execution_mode` ∈ `{create_issue, run_only}`.
- Trigger `kind` ∈ `{schedule, webhook}`.
- Schedule triggers require `cron_expression`.
- Signing secret min 16 chars.

### SQL snippets

```sql
CREATE TABLE autopilot (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    project_id UUID REFERENCES project(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    description TEXT,
    assignee_type TEXT NOT NULL DEFAULT 'agent',
    assignee_id UUID NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    execution_mode TEXT NOT NULL DEFAULT 'create_issue',
    issue_title_template TEXT,
    created_by_type TEXT NOT NULL,
    created_by_id UUID NOT NULL,
    last_run_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE autopilot_trigger (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    autopilot_id UUID NOT NULL REFERENCES autopilot(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('schedule','webhook','api')),
    enabled BOOLEAN NOT NULL DEFAULT true,
    cron_expression TEXT,
    timezone TEXT DEFAULT 'UTC',
    next_run_at TIMESTAMPTZ,
    webhook_token TEXT,
    label TEXT,
    last_fired_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE autopilot_run (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    autopilot_id UUID NOT NULL REFERENCES autopilot(id) ON DELETE CASCADE,
    trigger_id UUID REFERENCES autopilot_trigger(id) ON DELETE SET NULL,
    source TEXT NOT NULL CHECK (source IN ('schedule','manual','webhook','api')),
    status TEXT NOT NULL DEFAULT 'pending',
    issue_id UUID REFERENCES issue(id) ON DELETE SET NULL,
    task_id UUID REFERENCES agent_task_queue(id) ON DELETE SET NULL,
    triggered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    failure_reason TEXT,
    trigger_payload JSONB,
    result JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

- Autopilot CRUD should be real.
- Triggers/runs can return empty arrays in a stub.
- Manual trigger needs `AutopilotService`; stub with 501 or empty run.

---

## Chat Sessions / Messages

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/chat-sessions` | List sessions |
| POST | `/api/chat-sessions` | Create session |
| GET | `/api/chat-sessions/:sessionId` | Get session |
| PATCH | `/api/chat-sessions/:sessionId` | Update session |
| DELETE | `/api/chat-sessions/:sessionId` | Delete session |
| GET | `/api/chat-sessions/:sessionId/messages` | List messages |
| POST | `/api/chat-sessions/:sessionId/messages` | Send message |
| GET | `/api/chat-sessions/:sessionId/messages/page` | Paged messages |

### Go structs

```go
type ChatSessionResponse struct {
    ID          string `json:"id"`
    WorkspaceID string `json:"workspace_id"`
    AgentID     string `json:"agent_id"`
    CreatorID   string `json:"creator_id"`
    Title       string `json:"title"`
    Status      string `json:"status"`
    HasUnread   bool   `json:"has_unread"`
    CreatedAt   string `json:"created_at"`
    UpdatedAt   string `json:"updated_at"`
}

type ChatMessageResponse struct {
    ID            string               `json:"id"`
    ChatSessionID string               `json:"chat_session_id"`
    Role          string               `json:"role"`
    Content       string               `json:"content"`
    TaskID        *string              `json:"task_id"`
    CreatedAt     string               `json:"created_at"`
    FailureReason *string              `json:"failure_reason"`
    ElapsedMs     *int64               `json:"elapsed_ms"`
    Attachments   []AttachmentResponse `json:"attachments,omitempty"`
}

type CreateChatSessionRequest struct {
    AgentID string `json:"agent_id"`
    Title   string `json:"title"`
}

type UpdateChatSessionRequest struct {
    Title *string `json:"title"`
}

type SendChatMessageRequest struct {
    Content       string   `json:"content"`
    AttachmentIDs []string `json:"attachment_ids"`
}

type SendChatMessageResponse struct {
    MessageID string `json:"message_id"`
    TaskID    string `json:"task_id"`
    CreatedAt string `json:"created_at"`
}
```

### Validation

- `agent_id` required to create.
- `title` required for create/update.
- `content` required to send message.

### SQL snippets

```sql
CREATE TABLE chat_session (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    agent_id UUID NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
    creator_id UUID NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
    title TEXT NOT NULL DEFAULT '',
    session_id TEXT,
    work_dir TEXT,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE chat_message (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    chat_session_id UUID NOT NULL REFERENCES chat_session(id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('user','assistant')),
    content TEXT NOT NULL,
    task_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

- Chat session/message CRUD should be real for the chat UI.
- Sending a message spawns a task; stub may queue synchronously or return a placeholder `task_id`.

---

## Inbox

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/inbox` | List inbox items |
| POST | `/api/inbox/:id/read` | Mark read |
| POST | `/api/inbox/:id/archive` | Archive item |
| POST | `/api/inbox/read-all` | Mark all read |
| POST | `/api/inbox/archive-all` | Archive all |
| POST | `/api/inbox/archive-all-read` | Archive all read |

### Go structs

```go
type InboxItemResponse struct {
    ID            string          `json:"id"`
    WorkspaceID   string          `json:"workspace_id"`
    RecipientType string          `json:"recipient_type"`
    RecipientID   string          `json:"recipient_id"`
    Type          string          `json:"type"`
    Severity      string          `json:"severity"`
    IssueID       *string         `json:"issue_id"`
    Title         string          `json:"title"`
    Body          *string         `json:"body"`
    Read          bool            `json:"read"`
    Archived      bool            `json:"archived"`
    CreatedAt     string          `json:"created_at"`
    IssueStatus   *string         `json:"issue_status"`
    ActorType     *string         `json:"actor_type"`
    ActorID       *string         `json:"actor_id"`
    Details       json.RawMessage `json:"details"`
}
```

### SQL snippets

```sql
CREATE TABLE inbox_item (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    recipient_type TEXT NOT NULL CHECK (recipient_type IN ('member','agent')),
    recipient_id UUID NOT NULL,
    type TEXT NOT NULL,
    severity TEXT NOT NULL DEFAULT 'info',
    issue_id UUID REFERENCES issue(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    body TEXT,
    read BOOLEAN NOT NULL DEFAULT FALSE,
    archived BOOLEAN NOT NULL DEFAULT FALSE,
    actor_type TEXT,
    actor_id UUID,
    details JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

- List/mutations are simple; implement real queries early.

---

## Comments

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/issues/:id/comments` | List comments |
| POST | `/api/issues/:id/comments` | Create comment |
| PATCH | `/api/comments/:commentId` | Update comment |
| DELETE | `/api/comments/:commentId` | Delete comment |
| POST | `/api/comments/:commentId/resolve` | Resolve thread |

### Go structs

```go
type CommentResponse struct {
    ID               string               `json:"id"`
    IssueID          string               `json:"issue_id"`
    AuthorType       string               `json:"author_type"`
    AuthorID         string               `json:"author_id"`
    Content          string               `json:"content"`
    Type             string               `json:"type"`
    ParentID         *string              `json:"parent_id"`
    CreatedAt        string               `json:"created_at"`
    UpdatedAt        string               `json:"updated_at"`
    ResolvedAt       *string              `json:"resolved_at"`
    ResolvedByType   *string              `json:"resolved_by_type"`
    ResolvedByID     *string              `json:"resolved_by_id"`
    Reactions        []ReactionResponse   `json:"reactions"`
    Attachments      []AttachmentResponse `json:"attachments"`
    ReplyCount       *int                 `json:"reply_count,omitempty"`
    LastActivityAt   *string              `json:"last_activity_at,omitempty"`
    ContentTruncated *bool                `json:"content_truncated,omitempty"`
}

type CreateCommentRequest struct {
    Content          string   `json:"content"`
    Type             string   `json:"type"`
    ParentID         *string  `json:"parent_id"`
    AttachmentIDs    []string `json:"attachment_ids"`
    SuppressAgentIDs []string `json:"suppress_agent_ids"`
}
```

Update comment uses an inline struct:

```go
type _UpdateCommentRequest struct {
    Content       string    `json:"content"`
    AttachmentIDs *[]string `json:"attachment_ids"`
}
```

### Validation

- `content` required.
- `type` ∈ `{comment, status_change, progress_update, system}`.

### SQL snippets

```sql
CREATE TABLE comment (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    issue_id UUID NOT NULL REFERENCES issue(id) ON DELETE CASCADE,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    author_type TEXT NOT NULL CHECK (author_type IN ('member','agent','system')),
    author_id UUID NOT NULL,
    content TEXT NOT NULL,
    type TEXT NOT NULL DEFAULT 'comment',
    parent_id UUID REFERENCES comment(id) ON DELETE CASCADE,
    resolved_at TIMESTAMPTZ,
    resolved_by_type TEXT,
    resolved_by_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

- Comment CRUD should be real.
- Reactions can be omitted or returned empty.
- Resolve endpoint is a simple update.

---

## Attachments

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/issues/:id/attachments` | List issue attachments |
| POST | `/api/attachments` | Upload attachment (multipart) |
| GET | `/api/attachments/:id` | Get attachment |
| GET | `/api/attachments/:id/download` | Download |
| GET | `/api/attachments/:id/content` | Text preview |
| DELETE | `/api/attachments/:id` | Delete attachment |

### Go structs

```go
type AttachmentResponse struct {
    ID            string  `json:"id"`
    WorkspaceID   string  `json:"workspace_id"`
    IssueID       *string `json:"issue_id"`
    CommentID     *string `json:"comment_id"`
    ChatSessionID *string `json:"chat_session_id"`
    ChatMessageID *string `json:"chat_message_id"`
    UploaderType  string  `json:"uploader_type"`
    UploaderID    string  `json:"uploader_id"`
    Filename      string  `json:"filename"`
    URL           string  `json:"url"`
    DownloadURL   string  `json:"download_url"`
    MarkdownURL   string  `json:"markdown_url"`
    ContentType   string  `json:"content_type"`
    SizeBytes     int64   `json:"size_bytes"`
    CreatedAt     string  `json:"created_at"`
}
```

### SQL snippets

```sql
CREATE TABLE attachment (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    issue_id UUID REFERENCES issue(id) ON DELETE CASCADE,
    comment_id UUID REFERENCES comment(id) ON DELETE CASCADE,
    chat_session_id UUID REFERENCES chat_session(id) ON DELETE CASCADE,
    chat_message_id UUID REFERENCES chat_message(id) ON DELETE SET NULL,
    uploader_type TEXT NOT NULL CHECK (uploader_type IN ('member','agent')),
    uploader_id UUID NOT NULL,
    filename TEXT NOT NULL,
    url TEXT NOT NULL,
    content_type TEXT NOT NULL,
    size_bytes BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

- List/get/delete can be real without storage.
- Upload needs a storage backend; stub can save metadata with a placeholder URL.

---

## Tasks / `agent_task_queue`

### User-facing routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/issues/:id/tasks/active` | Active tasks for issue |
| GET | `/api/issues/:id/tasks` | All tasks for issue |
| POST | `/api/issues/:id/tasks/:taskId/cancel` | Cancel task |
| GET | `/api/tasks/:taskId/messages` | Task messages |
| GET | `/api/issues/:id/usage` | Token usage summary |
| POST | `/api/issues/:id/rerun` | Rerun issue |

### Daemon routes

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/daemon/runtimes/:runtimeId/claim` | Claim next task |
| POST | `/api/daemon/tasks/:taskId/start` | Start task |
| POST | `/api/daemon/tasks/:taskId/waiting-local-directory` | Park task |
| POST | `/api/daemon/tasks/:taskId/progress` | Progress update |
| POST | `/api/daemon/tasks/:taskId/complete` | Complete task |
| POST | `/api/daemon/tasks/:taskId/fail` | Fail task |
| GET | `/api/daemon/tasks/:taskId/status` | Task status |
| POST | `/api/daemon/tasks/:taskId/messages` | Report messages |
| POST | `/api/daemon/runtimes/:runtimeId/recover-orphans` | Recover orphans |

### Go structs

```go
type AgentTaskResponse struct {
    ID            string  `json:"id"`
    AgentID       string  `json:"agent_id"`
    RuntimeID     string  `json:"runtime_id"`
    IssueID       string  `json:"issue_id"`
    WorkspaceID   string  `json:"workspace_id"`
    Status        string  `json:"status"`
    Priority      int32   `json:"priority"`
    DispatchedAt  *string `json:"dispatched_at"`
    StartedAt     *string `json:"started_at"`
    CompletedAt   *string `json:"completed_at"`
    Result        any     `json:"result"`
    Error         *string `json:"error"`
    FailureReason string  `json:"failure_reason,omitempty"`
    Attempt       int32   `json:"attempt"`
    MaxAttempts   int32   `json:"max_attempts"`
    ParentTaskID  *string `json:"parent_task_id,omitempty"`
    CreatedAt     string  `json:"created_at"`
}

type TaskMessagePayload struct {
    TaskID    string         `json:"task_id"`
    IssueID   string         `json:"issue_id,omitempty"`
    Seq       int            `json:"seq"`
    Type      string         `json:"type"`
    Tool      string         `json:"tool,omitempty"`
    Content   string         `json:"content,omitempty"`
    Input     map[string]any `json:"input,omitempty"`
    Output    string         `json:"output,omitempty"`
    CreatedAt string         `json:"created_at,omitempty"`
}
```

### SQL snippets

```sql
CREATE TABLE agent_task_queue (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID NOT NULL REFERENCES agent(id) ON DELETE CASCADE,
    runtime_id UUID REFERENCES agent_runtime(id),
    issue_id UUID REFERENCES issue(id) ON DELETE CASCADE,
    chat_session_id UUID REFERENCES chat_session(id) ON DELETE SET NULL,
    autopilot_run_id UUID REFERENCES autopilot_run(id) ON DELETE SET NULL,
    status TEXT NOT NULL DEFAULT 'queued',
    priority INT NOT NULL DEFAULT 0,
    context JSONB,
    session_id TEXT,
    work_dir TEXT,
    trigger_comment_id UUID REFERENCES comment(id) ON DELETE SET NULL,
    trigger_summary TEXT,
    force_fresh_session BOOLEAN NOT NULL DEFAULT FALSE,
    attempt INT NOT NULL DEFAULT 1,
    max_attempts INT NOT NULL DEFAULT 2,
    parent_task_id UUID REFERENCES agent_task_queue(id) ON DELETE SET NULL,
    is_leader_task BOOLEAN NOT NULL DEFAULT FALSE,
    wait_reason TEXT,
    initiator_user_id UUID,
    dispatched_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    result JSONB,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE task_message (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES agent_task_queue(id) ON DELETE CASCADE,
    seq INT NOT NULL,
    type TEXT NOT NULL,
    tool TEXT,
    content TEXT,
    input JSONB,
    output TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE task_usage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    task_id UUID NOT NULL REFERENCES agent_task_queue(id) ON DELETE CASCADE,
    provider TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL,
    input_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    cache_read_tokens BIGINT NOT NULL DEFAULT 0,
    cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

| Route | Guidance |
|---|---|
| User list/get/cancel | Can return empty arrays / no-op in stub. |
| `GET /api/issues/:id/usage` | Can return zero totals. |
| Daemon claim/start/complete/fail/status | Need real state machine; defer. |
| `POST /api/daemon/tasks/:taskId/messages` | Real insert required if task messages are shown. |
| `POST /api/issues/:id/rerun` | Needs task service; stub or omit. |

---

## Runtimes

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/runtimes` | List runtimes |
| GET | `/api/runtimes/:runtimeId` | Get runtime |
| PATCH | `/api/runtimes/:runtimeId` | Update runtime |
| DELETE | `/api/runtimes/:runtimeId` | Delete runtime |
| GET | `/api/runtimes/:runtimeId/usage` | Usage trend |

### Go structs

```go
type AgentRuntimeResponse struct {
    ID           string  `json:"id"`
    WorkspaceID  string  `json:"workspace_id"`
    DaemonID     *string `json:"daemon_id"`
    Name         string  `json:"name"`
    RuntimeMode  string  `json:"runtime_mode"`
    Provider     string  `json:"provider"`
    LaunchHeader string  `json:"launch_header"`
    Status       string  `json:"status"`
    DeviceInfo   string  `json:"device_info"`
    Metadata     any     `json:"metadata"`
    OwnerID      *string `json:"owner_id"`
    Visibility   string  `json:"visibility"`
    LastSeenAt   *string `json:"last_seen_at"`
    CreatedAt    string  `json:"created_at"`
    UpdatedAt    string  `json:"updated_at"`
}

type UpdateAgentRuntimeRequest struct {
    Visibility *string `json:"visibility,omitempty"`
}

type RuntimeUsageResponse struct {
    RuntimeID        string `json:"runtime_id"`
    Date             string `json:"date"`
    Provider         string `json:"provider"`
    Model            string `json:"model"`
    InputTokens      int64  `json:"input_tokens"`
    OutputTokens     int64  `json:"output_tokens"`
    CacheReadTokens  int64  `json:"cache_read_tokens"`
    CacheWriteTokens int64  `json:"cache_write_tokens"`
}
```

### Validation

- `visibility` ∈ `{private, public}`.

### SQL snippets

```sql
CREATE TABLE agent_runtime (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    daemon_id TEXT,
    legacy_daemon_id TEXT,
    name TEXT NOT NULL,
    runtime_mode TEXT NOT NULL CHECK (runtime_mode IN ('local','cloud')),
    provider TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'offline',
    device_info TEXT NOT NULL DEFAULT '',
    metadata JSONB NOT NULL DEFAULT '{}',
    owner_id UUID REFERENCES "user"(id),
    visibility TEXT NOT NULL DEFAULT 'private',
    last_seen_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE runtime_usage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    runtime_id UUID NOT NULL REFERENCES agent_runtime(id) ON DELETE CASCADE,
    date DATE NOT NULL,
    provider TEXT NOT NULL,
    model TEXT NOT NULL DEFAULT '',
    input_tokens BIGINT NOT NULL DEFAULT 0,
    output_tokens BIGINT NOT NULL DEFAULT 0,
    cache_read_tokens BIGINT NOT NULL DEFAULT 0,
    cache_write_tokens BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (runtime_id, date, provider, model)
);
```

### Stub vs real queries

- Runtime list/get/update/delete should be real.
- Usage endpoint can return `[]` in Track F.

---

## Dashboard

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/dashboard/usage-daily` | Daily token usage |
| GET | `/api/dashboard/usage-by-agent` | Per-agent usage |
| GET | `/api/dashboard/agent-runtime` | Per-agent runtime |
| GET | `/api/dashboard/runtime-daily` | Daily runtime |

### Go structs

```go
type DashboardUsageDailyResponse struct {
    Date             string `json:"date"`
    Model            string `json:"model"`
    InputTokens      int64  `json:"input_tokens"`
    OutputTokens     int64  `json:"output_tokens"`
    CacheReadTokens  int64  `json:"cache_read_tokens"`
    CacheWriteTokens int64  `json:"cache_write_tokens"`
    TaskCount        int32  `json:"task_count"`
}

type DashboardUsageByAgentResponse struct {
    AgentID          string `json:"agent_id"`
    Model            string `json:"model"`
    InputTokens      int64  `json:"input_tokens"`
    OutputTokens     int64  `json:"output_tokens"`
    CacheReadTokens  int64  `json:"cache_read_tokens"`
    CacheWriteTokens int64  `json:"cache_write_tokens"`
    TaskCount        int32  `json:"task_count"`
}

type DashboardAgentRunTimeResponse struct {
    AgentID      string `json:"agent_id"`
    TotalSeconds int64  `json:"total_seconds"`
    TaskCount    int32  `json:"task_count"`
    FailedCount  int32  `json:"failed_count"`
}

type DashboardRunTimeDailyResponse struct {
    Date         string `json:"date"`
    TotalSeconds int64  `json:"total_seconds"`
    TaskCount    int32  `json:"task_count"`
    FailedCount  int32  `json:"failed_count"`
}
```

### Query params

- `days` (int)
- `project_id` (UUID, optional)
- `tz` (IANA timezone)

### Stub vs real queries

- **All dashboard endpoints can safely return empty arrays** in Track F.

---

## Cloud Billing

### Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/cloud-billing/balance` | Wallet balance |
| GET | `/api/cloud-billing/transactions` | Transactions |
| GET | `/api/cloud-billing/batches` | Batches |
| GET | `/api/cloud-billing/topups` | Topups |
| GET | `/api/cloud-billing/price-tiers` | Price tiers |
| POST | `/api/cloud-billing/checkout-sessions` | Create checkout session |
| GET | `/api/cloud-billing/checkout-sessions/:sessionId` | Get checkout session |
| POST | `/api/cloud-billing/portal-sessions` | Create portal session |
| POST | `/api/webhooks/stripe` | Stripe webhook |

### Notes

All endpoints proxy to the 1person-cloud billing service (`/api/v1/billing/*`). There are no local tables.

### Stub vs real queries

- **All cloud-billing routes can safely return empty or 503 stub responses** in Track F.

---

## Daemon

### Routes

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/daemon/register` | Register daemon + runtimes |
| POST | `/api/daemon/heartbeat` | Runtime heartbeat |
| POST | `/api/daemon/runtimes/:runtimeId/claim` | Claim task |
| POST | `/api/daemon/tasks/:taskId/start` | Start task |
| POST | `/api/daemon/tasks/:taskId/waiting-local-directory` | Park task |
| POST | `/api/daemon/tasks/:taskId/progress` | Progress |
| POST | `/api/daemon/tasks/:taskId/complete` | Complete |
| POST | `/api/daemon/tasks/:taskId/fail` | Fail |
| GET | `/api/daemon/tasks/:taskId/status` | Status |
| POST | `/api/daemon/tasks/:taskId/messages` | Report messages |
| POST | `/api/daemon/tasks/:taskId/pin-session` | Pin session |
| POST | `/api/daemon/runtimes/:runtimeId/recover-orphans` | Recover orphans |
| GET | `/api/daemon/issues/:issueId/gc-check` | Issue GC check |
| GET | `/api/daemon/chat-sessions/:sessionId/gc-check` | Chat GC check |

### Go structs

```go
type DaemonRegisterRequest struct {
    WorkspaceID     string `json:"workspace_id"`
    DaemonID        string `json:"daemon_id"`
    LegacyDaemonIDs []string `json:"legacy_daemon_ids"`
    DeviceName      string `json:"device_name"`
    CLIVersion      string `json:"cli_version"`
    LaunchedBy      string `json:"launched_by"`
    Runtimes        []struct {
        Name    string `json:"name"`
        Type    string `json:"type"`
        Version string `json:"version"`
        Status  string `json:"status"`
    } `json:"runtimes"`
}

type DaemonHeartbeatRequest struct {
    RuntimeID           string `json:"runtime_id"`
    SupportsBatchImport bool   `json:"supports_batch_import,omitempty"`
}
```

### SQL snippets

```sql
CREATE TABLE daemon_token (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    token_hash TEXT NOT NULL,
    workspace_id UUID NOT NULL REFERENCES workspace(id) ON DELETE CASCADE,
    daemon_id TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```

### Stub vs real queries

| Route | Guidance |
|---|---|
| `POST /api/daemon/register` | Minimal upsert of `agent_runtime` rows. |
| `POST /api/daemon/heartbeat` | Runtime upsert + ack; stub with `{"status":"ok"}`. |
| `POST .../claim` | Needs real task queue state machine. |
| `POST .../start/complete/fail` | Needs real task service. |
| `POST .../messages` | Needs real `task_message` inserts. |
| GC checks | Minimal `{"status": "..."}` stubs. |

---

## Summary: Safe Empty-Array Stub Routes

These routes do not need real persistence in the first Track F stub:

- Dashboard: all
- Cloud billing: all
- Runtime usage: `/api/runtimes/:id/usage`
- Task user-facing list/get: `/api/issues/:id/tasks*`, `/api/tasks/:id/messages`
- Task usage summary: `/api/issues/:id/usage`
- Autopilot triggers/runs
- Agent env endpoints
- Project resources
- Skill search/import

Everything else (issues, projects, labels, squads, agents, skills, autopilots, chat sessions/messages, inbox, comments, attachments, runtime CRUD) should be wired to real table queries for the product UI to function.
