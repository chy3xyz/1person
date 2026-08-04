"use client"

import { cn } from "@1person/ui/lib/utils";

export interface CommissionRecord {
  id: string;
  fromUserId: string;
  fromUserName: string;
  toUserId: string;
  toUserName: string;
  amount: number;
  rate: number;
  level: number;
  status: "pending" | "settled";
  createdAt: string;
}

export interface CommissionTableProps {
  records: CommissionRecord[];
  currency?: string;
  className?: string;
  showUser?: boolean;
}

const STATUS_STYLES: Record<CommissionRecord["status"], string> = {
  pending: "bg-amber-100 text-amber-700 dark:bg-amber-900 dark:text-amber-300",
  settled: "bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300",
};

export function CommissionTable({
  records,
  currency = "¥",
  className,
  showUser = true,
}: CommissionTableProps) {
  if (!records.length) {
    return (
      <div className="p-4 text-center text-sm text-muted-foreground">
        No commission records
      </div>
    );
  }

  const total = records.reduce((sum, r) => sum + r.amount, 0);

  return (
    <div className={cn("overflow-x-auto", className)}>
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-border text-muted-foreground">
            {showUser && <th className="text-left py-2 px-3 font-medium">From</th>}
            <th className="text-left py-2 px-3 font-medium">To</th>
            <th className="text-right py-2 px-3 font-medium">Amount</th>
            <th className="text-right py-2 px-3 font-medium">Rate</th>
            <th className="text-center py-2 px-3 font-medium">Level</th>
            <th className="text-center py-2 px-3 font-medium">Status</th>
          </tr>
        </thead>
        <tbody>
          {records.map((r) => (
            <tr key={r.id} className="border-b border-border/50 hover:bg-muted/50 transition-colors">
              {showUser && (
                <td className="py-2 px-3 text-muted-foreground">{r.fromUserName}</td>
              )}
              <td className="py-2 px-3">{r.toUserName}</td>
              <td className="py-2 px-3 text-right font-mono tabular-nums">
                {currency}{r.amount.toLocaleString()}
              </td>
              <td className="py-2 px-3 text-right font-mono tabular-nums text-muted-foreground">
                {(r.rate * 100).toFixed(0)}%
              </td>
              <td className="py-2 px-3 text-center text-muted-foreground">
                L{r.level}
              </td>
              <td className="py-2 px-3 text-center">
                <span className={cn("text-xs px-1.5 py-0.5 rounded-full font-medium", STATUS_STYLES[r.status])}>
                  {r.status}
                </span>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr className="border-t-2 border-border font-semibold">
            {showUser && <td className="py-2 px-3" />}
            <td className="py-2 px-3">Total</td>
            <td className="py-2 px-3 text-right font-mono tabular-nums">
              {currency}{total.toLocaleString()}
            </td>
            <td colSpan={3} />
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
