// Connector types for third-party integrations (GitHub, Linear, Jira,
// Slack, etc.). Each connector is a workspace-level config that agents
// use to call external APIs.

export type ConnectorProvider =
  | "github"
  | "linear"
  | "jira"
  | "slack"
  | "lark"
  | "notion"
  | "custom";

export type ConnectorAuthMethod = "oauth2" | "api_key" | "token";

export interface ConnectorConfig {
  id: string;
  workspaceId: string;
  provider: ConnectorProvider;
  authMethod: ConnectorAuthMethod;
  /** Arbitrary key-value store for provider-specific settings. */
  settings: Record<string, unknown>;
  /** Whether agents are allowed to call APIs through this connector. */
  enabled: boolean;
  /** User ID of the member who set up this connector. */
  createdBy: string;
  createdAt: string;
  updatedAt: string;
}

export interface ApiCallLog {
  id: string;
  connectorId: string;
  workspaceId: string;
  /** Agent or user ID that triggered this call. */
  callerId: string;
  /** HTTP method used. */
  method: string;
  /** Full URL (redacted query params except documented ones). */
  url: string;
  /** HTTP status code returned. */
  statusCode: number;
  /** Duration in milliseconds. */
  durationMs: number;
  /** Whether the call returned a non-2xx status or timed out. */
  isError: boolean;
  /** Truncated error message when isError is true. */
  errorMessage?: string;
  calledAt: string;
}
