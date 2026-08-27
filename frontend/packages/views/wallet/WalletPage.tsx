"use client";

import { useQuery } from "@tanstack/react-query";
import { Wallet, ArrowUpCircle, ArrowDownCircle, Gift } from "lucide-react";
import { useWorkspaceId } from "@1person/core/hooks";
import { Button } from "@1person/ui/components/ui/button";

export function WalletPage() {
  const wsId = useWorkspaceId();

  const fetchWallet = () =>
    fetch(`/api/wallet/me`, { headers: { "X-Workspace-Id": wsId } })
      .then((r) => r.json())
      .catch(() => ({}));

  const fetchTxns = () =>
    fetch(`/api/wallet/transactions`, { headers: { "X-Workspace-Id": wsId } })
      .then((r) => r.json())
      .then((j) => (j.transactions ?? []) as any[])
      .catch(() => []);

  const wallet = useQuery({
    queryKey: ["wallet", wsId],
    queryFn: fetchWallet,
    enabled: !!wsId,
  });

  const txns = useQuery({
    queryKey: ["wallet", wsId, "transactions"],
    queryFn: fetchTxns,
    enabled: !!wsId,
  });

  const data: any = wallet.data ?? {};
  const txnList: any[] = txns.data ?? [];

  return (
    <div className="flex h-full flex-col">
      <header className="flex items-center gap-2 px-5 py-3">
        <Wallet className="h-4 w-4 text-muted-foreground" />
        <h1 className="text-sm font-medium">Wallet</h1>
      </header>

      <div className="flex-1 overflow-y-auto p-5 space-y-4">
        {/* Balance Card */}
        <div className="rounded-xl border bg-card p-6">
          <div className="flex items-end gap-4">
            <div>
              <span className="text-3xl font-bold">
                ¥{(data.balanceFiat ?? 0).toLocaleString()}
              </span>
              <span className="text-sm text-muted-foreground ml-1">fiat</span>
            </div>
            {(data.balanceReward ?? 0) > 0 && (
              <div className="text-green-600">
                <span className="text-lg font-semibold">+{data.balanceReward}</span>
                <span className="text-xs ml-1">rewards</span>
              </div>
            )}
          </div>
          <div className="flex gap-2 mt-4">
            <Button size="sm"><ArrowUpCircle className="h-4 w-4 mr-1"/>Deposit</Button>
            <Button size="sm" variant="outline"><ArrowDownCircle className="h-4 w-4 mr-1"/>Withdraw</Button>
            <Button size="sm" variant="outline"><Gift className="h-4 w-4 mr-1"/>Reward</Button>
          </div>
        </div>

        {/* Transactions */}
        <div>
          <h3 className="text-sm font-medium mb-2">Transactions</h3>
          {txnList.length === 0 ? (
            <p className="text-sm text-muted-foreground">No transactions yet.</p>
          ) : (
            txnList.map((tx: any) => (
              <div key={tx.id} className="flex justify-between border-b py-2 text-sm">
                <span>{tx.type}</span>
                <span className={tx.type === "deposit" || tx.type === "reward" ? "text-green-600" : "text-red-600"}>
                  ¥{tx.amount.toLocaleString()}
                </span>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
