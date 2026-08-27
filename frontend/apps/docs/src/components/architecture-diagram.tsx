// 1Person architecture diagram (Solid port of components/architecture-diagram.tsx).
// Boundary-style layout: "Your side" panel + "1Person" panel.
export function ArchitectureDiagram() {
  return (
    <div class="not-prose my-8">
      <div class="hidden md:grid md:grid-cols-[1.7fr_auto_1fr] md:gap-4 md:items-stretch">
        <YourSide />
        <Connector horizontal />
        <PlatformSide />
      </div>
      <div class="md:hidden space-y-4">
        <YourSide />
        <Connector horizontal={false} />
        <PlatformSide />
      </div>
    </div>
  );
}

function YourSide() {
  return (
    <div class="rounded-lg border border-brand/30 bg-brand/[0.03] p-6 flex flex-col">
      <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-brand mb-5">Your side</div>
      <div class="flex-1 space-y-5">
        <div>
          <SectionLabel>Client</SectionLabel>
          <div class="flex flex-wrap gap-2">
            <Pill>Web app</Pill>
            <Pill>CLI</Pill>
          </div>
        </div>
        <div class="h-px bg-brand/15" />
        <div>
          <SectionLabel>Daemon</SectionLabel>
          <div class="text-xs text-muted-foreground mb-2.5">
            Polls work from 1Person. Invokes local AI coding tools:
          </div>
          <div class="flex flex-wrap gap-1.5">
            <Pill>Claude Code</Pill>
            <Pill>Codex</Pill>
            <Pill>Cursor</Pill>
            <Pill>Copilot</Pill>
            <Pill muted>+ 6 more</Pill>
          </div>
        </div>
      </div>
      <div class="mt-6 pt-4 border-t border-brand/20 flex items-center justify-center gap-3 text-[13px] font-medium text-brand">
        <span>Your code.</span>
        <span class="text-brand/40">·</span>
        <span>Your keys.</span>
        <span class="text-brand/40">·</span>
        <span>Your CPU.</span>
      </div>
    </div>
  );
}

function PlatformSide() {
  return (
    <div class="rounded-lg border border-border/70 bg-muted/25 p-6 flex flex-col">
      <div class="text-[11px] font-semibold uppercase tracking-[0.12em] text-muted-foreground mb-5">1Person</div>
      <div class="flex-1 flex flex-col">
        <SectionLabel>Server</SectionLabel>
        <div class="text-xs text-muted-foreground mb-4">Cloud or self-hosted</div>
        <div class="text-xs space-y-1.5 text-foreground/80">
          <div>Workspaces</div>
          <div>Issues &amp; tasks</div>
          <div>Agent definitions</div>
          <div>Realtime (WebSocket)</div>
        </div>
      </div>
      <div class="mt-6 pt-4 border-t border-border/60 text-[11px] text-muted-foreground text-center uppercase tracking-[0.08em]">
        No AI execution here.
      </div>
    </div>
  );
}

function Connector(props: { horizontal: boolean }) {
  return (
    <div
      class="flex items-center justify-center text-muted-foreground/50 text-xl select-none px-1"
      aria-hidden="true"
    >
      {props.horizontal ? "⇄" : "⇅"}
    </div>
  );
}

function SectionLabel(props: { children?: any }) {
  return (
    <div class="mb-2 text-[11px] font-semibold uppercase tracking-[0.1em] text-muted-foreground">
      {props.children}
    </div>
  );
}

function Pill(props: { children?: any; muted?: boolean }) {
  return (
    <span
      class={"rounded-[4px] border px-2 py-1 text-[11px] " + (props.muted ? "border-border/70 text-muted-foreground" : "border-border bg-card text-foreground/80")}
    >
      {props.children}
    </span>
  );
}
