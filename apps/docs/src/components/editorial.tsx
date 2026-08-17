import { For } from "solid-js";
import { useDocsLocale } from "~/components/locale-link";
import { prefixLocale } from "~/lib/locale-link";

/**
 * Byline — editorial metadata strip with ruled top + bottom borders.
 */
export function Byline(props: { items: string[] }) {
  return (
    <div class="not-prose mb-9 flex items-center gap-3.5 border-y border-[var(--docs-rule)] py-3.5 text-xs uppercase tracking-[0.08em] text-muted-foreground">
      <For each={props.items}>
        {(item, i) => (
          <span class="flex items-center gap-3.5">
            {i() > 0 ? <span class="size-[3px] rounded-full bg-[var(--docs-faint)]" /> : null}
            <span>{item}</span>
          </span>
        )}
      </For>
    </div>
  );
}

/**
 * NumberedCards — three-column ruled-divider grid with serif numbers.
 */
export function NumberedCards(props: { children?: any }) {
  return (
    <div class="not-prose my-9 grid grid-cols-1 border-y border-[var(--docs-rule)] md:grid-cols-3">
      {props.children}
    </div>
  );
}

export function NumberedCard(props: {
  number?: string;
  title: string;
  href: string;
  tag?: string;
  children?: any;
}) {
  const lang = useDocsLocale();
  return (
    <a
      href={prefixLocale(props.href, lang)}
      class="group flex flex-col gap-2.5 border-r border-border px-0 py-5 pr-4 no-underline last:border-r-0 md:px-4 md:first:pl-0 md:last:pr-0"
    >
      <div class="font-mono text-[0.6875rem] uppercase tracking-[0.08em] text-muted-foreground">
        {props.number ? `No. ${props.number}` : null}
      </div>
      <div class="font-[family-name:var(--font-serif)] text-[1.375rem] leading-[1.25] tracking-[-0.015em] text-foreground transition-colors group-hover:text-[var(--primary)]">
        {props.title}
      </div>
      <div class="text-[0.84375rem] leading-[1.55] text-muted-foreground">{props.children}</div>
      {props.tag ? (
        <div class="mt-1 font-mono text-[0.625rem] uppercase tracking-[0.06em] text-[var(--primary)]">
          {props.tag}
        </div>
      ) : null}
    </a>
  );
}

export function NumberedSteps(props: { children?: any }) {
  return <div class="not-prose my-7 border-t border-border">{props.children}</div>;
}

export function Step(props: { number: string; title: string; children?: any }) {
  return (
    <div class="grid grid-cols-[3.5rem_1fr] gap-5 border-b border-border py-5">
      <div class="font-[family-name:var(--font-serif)] text-[2rem] font-normal leading-none tracking-[-0.02em] text-[var(--primary)]">
        {props.number}
      </div>
      <div>
        <div class="mb-1 font-[family-name:var(--font-serif)] text-[1.25rem] leading-[1.3] tracking-[-0.01em] text-foreground">
          {props.title}
        </div>
        <div class="text-[0.9375rem] leading-[1.6] text-muted-foreground">{props.children}</div>
      </div>
    </div>
  );
}
