// Minimal headless dropdown menu (Solid). Used by DocsSettings — the
// legacy @1person/ui menu is React-only, so docs self-contains a tiny one.
import { createSignal, onCleanup, onMount, Show, type JSX } from "solid-js";

export function DropdownMenu(props: {
  trigger: (toggle: () => void, open: boolean) => JSX.Element;
  children: (close: () => void) => JSX.Element;
  align?: "start" | "end";
  side?: "top" | "bottom";
  class?: string;
}) {
  const [open, setOpen] = createSignal(false);
  const toggle = () => setOpen((v) => !v);
  const close = () => setOpen(false);

  onMount(() => {
    const onDocClick = (e: MouseEvent) => {
      const target = e.target as HTMLElement;
      if (!target.closest("[data-docs-menu]")) close();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
    };
    document.addEventListener("click", onDocClick);
    document.addEventListener("keydown", onKey);
    onCleanup(() => {
      document.removeEventListener("click", onDocClick);
      document.removeEventListener("keydown", onKey);
    });
  });

  return (
    <div data-docs-menu class={"relative inline-block " + (props.class ?? "")}>
      {props.trigger(toggle, open())}
      <Show when={open()}>
        <div
          class={
            "absolute z-50 min-w-[140px] rounded-md border border-border bg-popover p-1 text-popover-foreground shadow-lg " +
            (props.side === "top" ? "bottom-full mb-1 " : "top-full mt-1 ") +
            (props.align === "end" ? "right-0" : "left-0")
          }
          role="menu"
        >
          {props.children(close)}
        </div>
      </Show>
    </div>
  );
}
