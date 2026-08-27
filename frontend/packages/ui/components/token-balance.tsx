"use client"

import { cn } from "@1person/ui/lib/utils";

export interface TokenBalanceProps {
  balance: number;
  tokenName?: string;
  tokenSymbol?: string;
  className?: string;
  onEarn?: () => void;
  onSpend?: () => void;
}

export function TokenBalance({
  balance,
  tokenName = "Token",
  tokenSymbol = "TKN",
  className,
  onEarn,
  onSpend,
}: TokenBalanceProps) {
  return (
    <div className={cn("rounded-xl border border-border bg-card p-5 shadow-sm", className)}>
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-medium text-muted-foreground">{tokenName}</h3>
        <span className="text-xs px-2 py-0.5 rounded-full bg-primary/10 text-primary font-mono">
          {tokenSymbol}
        </span>
      </div>
      <div className="text-2xl font-bold tracking-tight mb-4">
        {balance.toLocaleString()}
        <span className="text-sm font-normal text-muted-foreground ml-1">{tokenSymbol}</span>
      </div>
      <div className="flex gap-2">
        {onEarn && (
          <button
            type="button"
            onClick={onEarn}
            className="flex-1 rounded-lg bg-green-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-green-700 transition-colors"
          >
            Earn
          </button>
        )}
        {onSpend && (
          <button
            type="button"
            onClick={onSpend}
            disabled={balance <= 0}
            className="flex-1 rounded-lg border border-border bg-background px-3 py-1.5 text-xs font-medium hover:bg-muted transition-colors disabled:opacity-50"
          >
            Spend
          </button>
        )}
      </div>
    </div>
  );
}
