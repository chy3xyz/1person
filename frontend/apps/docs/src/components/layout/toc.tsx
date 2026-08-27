import { For } from "solid-js";
import { getUiText } from "~/lib/translations";
import type { Lang } from "~/lib/i18n";

export type TocItem = { depth: number; text: string; id: string };

export function Toc(props: { items: TocItem[]; lang: Lang }) {
  if (props.items.length === 0) return null;
  return (
    <nav class="sticky top-16 hidden max-h-[calc(100vh-6rem)] overflow-y-auto xl:block" aria-label="Table of contents">
      <p class="mb-3 text-[0.6875rem] font-semibold uppercase tracking-[0.1em] text-muted-foreground">
        {getUiText(props.lang, "toc")}
      </p>
      <ul class="space-y-1 border-l border-border/70">
        <For each={props.items}>
          {(item) => (
            <li>
              <a
                href={"#" + item.id}
                class={
                  "block -ml-px border-l border-transparent py-1 pr-2 text-[0.8125rem] leading-snug no-underline text-muted-foreground transition-colors hover:border-[var(--primary)] hover:text-foreground " +
                  (item.depth === 3 ? "pl-5" : "pl-3")
                }
              >
                {item.text}
              </a>
            </li>
          )}
        </For>
      </ul>
    </nav>
  );
}
