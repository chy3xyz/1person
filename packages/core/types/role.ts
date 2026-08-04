/** Role definition — a named position within the workspace hierarchy. */
export interface RoleDef {
  id: string;
  workspace_id: string;
  name: string;
  description: string | null;
  /** Ordered position within the workspace hierarchy. */
  position: number;
  created_at: string;
  updated_at: string;
}

export interface CreateRoleDefRequest {
  name: string;
  description?: string;
  position?: number;
}

export interface UpdateRoleDefRequest {
  name?: string;
  description?: string;
  position?: number;
}

/** Maps a workspace member (user) to a role definition. */
export interface MemberRoleAssignment {
  id: string;
  workspace_id: string;
  user_id: string;
  role_def_id: string;
  created_at: string;
  updated_at: string;
}

export interface CreateMemberRoleRequest {
  user_id: string;
  role_def_id: string;
}

export interface UpdateMemberRoleRequest {
  role_def_id: string;
}
