"use client";

import { use } from "react";
import { IssueDetail } from "@1person/views/issues/components";
import { ErrorBoundary } from "@1person/ui/components/common/error-boundary";

export default function IssueDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = use(params);
  return (
    <ErrorBoundary resetKeys={[id]}>
      <IssueDetail issueId={id} />
    </ErrorBoundary>
  );
}
