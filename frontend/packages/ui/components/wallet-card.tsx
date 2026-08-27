"use client"

import { cn } from "@1person/ui/lib/utils";

export interface WalletCardProps {
  balanceFiat: number;
  balanceReward: number;
  currency?: string;
  className?: string;
  onDeposit?: () => void;
  onWithdraw?: () => void;
}

export function WalletCard({
  balanceFiat,
  balanceReward,
  currency = "¥",
  className,
  onDeposit,
  onWithdraw,
}: WalletCardProps) {
  return (
    <div className={cn("rounded-xl border border-border bg-card p-6 shadow-sm", className)}>
      <h3 className="text-sm font-medium text-muted-foreground mb-4">Wallet Balance</h3>
      <div className="flex items-end gap-4 mb-6">
        <div>
          <span className="text-3xl font-bold tracking-tight">
            {currency}{balanceFiat.toLocaleString()}
          </span>
          <span className="text-sm text-muted-foreground ml-1">fiat</span>
        </div>
        {balanceReward > 0 && (
          <div className="text-green-600 dark:text-green-400 pb-0.5">
            <span className="text-lg font-semibold">+{balanceReward}</span>
            <span className="text-xs ml-1">rewards</span>
          </div>
        )}
      </div>
      <div className="flex gap-2">
        {onDeposit && (
          <button
            type="button"
            onClick={onDeposit}
            className="flex-1 rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 transition-colors"
          >
            Deposit
          </button>
        )}
        {onWithdraw && (
          <button
            type="button"
            onClick={onWithdraw}
            disabled={balanceFiat <= 0}
            className="flex-1 rounded-lg border border-border bg-background px-4 py-2 text-sm font-medium hover:bg-muted transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Withdraw
          </button>
        )}
      </div>
    </div>
  );
}
