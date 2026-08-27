// Analytics v2 types — supersedes the v1 analytics embedded in the
// dashboard. V2 introduces time-series aggregation and named reports.

export interface Metric {
  id: string;
  workspaceId: string;
  name: string;
  /** Aggregation key: e.g. "issue_created", "agent_run_seconds". */
  key: string;
  unit: string;
  /** Current aggregate value for the selected window. */
  value: number;
  /** Change compared to the previous window (fraction, e.g. 0.15 = +15%). */
  delta: number;
  updatedAt: string;
}

export interface TimeSeriesPoint {
  /** ISO-8601 timestamp representing the bucket start. */
  timestamp: string;
  value: number;
}

export interface Report {
  id: string;
  workspaceId: string;
  name: string;
  /** Metric keys included in this report. */
  metricKeys: string[];
  /** Time-range presets accepted by the query engine. */
  range: "today" | "week" | "month" | "quarter" | "custom";
  /** Only set when range is "custom"; ISO-8601 strings. */
  rangeStart?: string;
  rangeEnd?: string;
  /** Resolution controls time-series bucket width. */
  resolution: "hour" | "day" | "week";
  series: TimeSeriesPoint[];
  createdAt: string;
}
