export type TokenTransactionType = "deposit" | "withdraw" | "reward";
export type TokenTransactionStatus = "pending" | "completed" | "failed";

export interface TokenBalance {
  userId: string;
  workspaceId: string;
  balance: number;
  /** ISO timestamp of the last update. */
  updatedAt: string;
}

export interface TokenTransaction {
  id: string;
  userId: string;
  workspaceId: string;
  amount: number;
  type: TokenTransactionType;
  status: TokenTransactionStatus;
  createdAt: string;
}
