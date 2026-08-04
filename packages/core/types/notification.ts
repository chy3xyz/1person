// Mirrors the notification-service response shapes. These types are the
// contract the frontend consumes for template management and delivery logs.
// Keep field names aligned with the server-side schema.

export type NotificationChannel = "email" | "in_app" | "push" | "slack";

export interface NotificationTemplate {
  id: string;
  workspaceId: string;
  name: string;
  channel: NotificationChannel;
  subjectTemplate: string;
  bodyTemplate: string;
  /** JSON-serialized variable defaults used when rendering. */
  variables: Record<string, unknown>;
  createdAt: string;
  updatedAt: string;
}

export interface NotificationLog {
  id: string;
  workspaceId: string;
  templateId: string;
  recipientId: string;
  channel: NotificationChannel;
  /** Rendered subject after variable interpolation. */
  subject: string;
  /** Rendered body after variable interpolation. */
  body: string;
  status: "sent" | "failed" | "bounced";
  /** Present only when status is "failed" or "bounced". */
  errorMessage?: string;
  sentAt: string;
}
