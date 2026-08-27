export type WalletTransactionType = "deposit" | "withdraw" | "reward";
export type WalletTransactionStatus = "pending" | "completed" | "failed";

export interface Wallet {
  id: string;
  userId: string;
  workspaceId: string;
  balanceFiat: number;
  balanceReward: number;
}

export interface WalletTransaction {
  id: string;
  walletId: string;
  amount: number;
  type: WalletTransactionType;
  status: WalletTransactionStatus;
  createdAt: string;
}
