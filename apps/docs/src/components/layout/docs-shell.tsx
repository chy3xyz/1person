import type { ParentProps } from "solid-js";

export function DocsShell(props: ParentProps) {
  return <main class="mx-auto max-w-[var(--fd-page-width)] px-4 py-8">{props.children}</main>;
}
