"use client";

import { DashboardLayout } from "@1person/views/layout";
import { 1PersonIcon } from "@1person/ui/components/common/1person-icon";
import { SearchCommand, SearchTrigger } from "@1person/views/search";
import { ChatFab, ChatWindow } from "@1person/views/chat";
import { WebNotificationBridge } from "@/components/web-notification-bridge";

export default function Layout({ children }: { children: React.ReactNode }) {
  return (
    <DashboardLayout
      loadingIndicator={<1PersonIcon className="size-6" />}
      searchSlot={<SearchTrigger />}
      extra={
        <>
          <SearchCommand />
          <ChatWindow />
          <ChatFab />
          <WebNotificationBridge />
        </>
      }
    >
      {children}
    </DashboardLayout>
  );
}
