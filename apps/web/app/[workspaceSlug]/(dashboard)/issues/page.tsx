"use client";

import { IssuesPage } from "@1person/views/issues/components";
import { ErrorBoundary } from "@1person/ui/components/common/error-boundary";

export default function Page() {
  return (
    <ErrorBoundary>
      <IssuesPage />
    </ErrorBoundary>
  );
}
