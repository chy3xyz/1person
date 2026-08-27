// Blockchain integration types for on-chain agent operations.
// These shapes cover chain configuration, wallet management, and
// transaction tracking separate from the in-app Wallet (see wallet.ts).

export type ChainFamily = "ethereum" | "solana" | "polygon" | "arbitrum" | "base";

export interface ChainConfig {
  id: string;
  workspaceId: string;
  family: ChainFamily;
  /** Chain ID per EIP-155 / network identifier. */
  chainId: number;
  /** RPC endpoint URL used by agents for read calls. */
  rpcUrl: string;
  /** Optional WebSocket RPC URL for event subscriptions. */
  wsUrl?: string;
  /** Block explorer base URL (e.g. "https://etherscan.io"). */
  explorerUrl?: string;
  /** Native currency symbol (e.g. "ETH", "SOL"). */
  nativeSymbol: string;
  enabled: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface BlockchainWallet {
  id: string;
  workspaceId: string;
  chainConfigId: string;
  /** Public address on the configured chain. */
  address: string;
  /** Human-readable label set by the workspace admin. */
  label: string;
  /** Whether this wallet is funded and ready for agent use. */
  active: boolean;
  createdAt: string;
}

export interface BlockchainTransaction {
  id: string;
  walletId: string;
  workspaceId: string;
  /** On-chain transaction hash. */
  txHash: string;
  /** Destination address or contract. */
  to: string;
  /** Native token amount in smallest unit (wei, lamports). */
  value: string;
  /** Optional calldata or contract method signature. */
  data?: string;
  status: "pending" | "confirmed" | "failed";
  /** Block number where confirmed; null while pending. */
  blockNumber?: number;
  /** Gas used (null before confirmation). */
  gasUsed?: string;
  createdAt: string;
  confirmedAt?: string;
}
