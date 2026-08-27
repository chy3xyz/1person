export type CommissionRecordStatus = "pending" | "settled";

export interface CommissionLevel {
  depth: number;
  rate: number;
  role?: string;
}

export interface CommissionRule {
  id: string;
  workspaceId: string;
  name: string;
  levels: CommissionLevel[];
  createdAt: string;
}

export interface CommissionRecord {
  id: string;
  transactionId: string;
  fromUserId: string;
  toUserId: string;
  amount: number;
  rate: number;
  level: number;
  status: CommissionRecordStatus;
  createdAt: string;
  settledAt: string | null;
}
