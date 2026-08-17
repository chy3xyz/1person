import { Show } from "solid-js";
import { ArrowLeftIcon, ArrowRightIcon } from "~/components/icons";
import { getUiText } from "~/lib/translations";
import type { Lang } from "~/lib/i18n";
import { toDocsHref } from "~/lib/locale-link";
import type { TocItem } from "~/components/layout/toc";

/**
 * Standard docs page skeleton: breadcrumb, title, description, MDX body,
 * prev/next footer. Mirrors the Fumadocs DocsPage surface the Next site used.
 */
export function DocsPage(props: {
  lang: Lang;
  title?: string;
  description?: string;
  breadcrumb?: string[];
  children: any;
  toc?: TocItem[];
  prev?: string | null;
  next?: string | null;
  prevTitle?: string | null;
  nextTitle?: string | null;
  header?: any;
}) {
  return (
    <article class="min-w-0">
      {props.header}
      <Show when={props.breadcrumb && props.breadcrumb.length > 0}>
        <nav class="mb-4 flex items-center gap-1.5 text-xs text-muted-foreground" aria-label="Breadcrumb">
          {props.breadcrumb?.map((crumb, i) => (
            <span class="flex items-center gap-1.5">
              {i > 0 ? <span class="text-border">/</span> : null}
              <span>{crumb}</span>
            </span>
          ))}
        </nav>
      </Show>
      <Show when={props.title}>
        <h1 class="docs-title font-[family-name:var(--font-serif)] text-[1.875rem] font-normal leading-[1.15] tracking-[-0.02em] text-foreground">
          {props.title}
        </h1>
      </Show>
      <Show when={props.description}>
        <p class="docs-description mt-2 max-w-[38rem] text-[1.0625rem] leading-[1.6] text-muted-foreground">{props.description}</p>
      </Show>
      <div class="prose docs-prose mt-8 max-w-none">{props.children}</div>
      <Show when={props.prev || props.next}>
        <nav class="mt-12 grid grid-cols-2 gap-3 border-t border-border/70 pt-6" aria-label="Pagination">
          <Show when={props.prev}>
            <a
              href={toDocsHref(props.prev!)}
              class="group flex flex-col gap-1 rounded-[4px] border border-border/70 p-3 no-underline transition-colors hover:border-[var(--primary)]"
            >
              <span class="flex items-center gap-1 text-xs text-muted-foreground">
                <ArrowLeftIcon class="size-3" />
                {getUiText(props.lang, "previousPage")}
              </span>
              <span class="text-sm font-medium text-foreground">{props.prevTitle}</span>
            </a>
          </Show>
          <Show when={props.next}>
            <a
              href={toDocsHref(props.next!)}
              class="group flex flex-col items-end gap-1 rounded-[4px] border border-border/70 p-3 text-right no-underline transition-colors hover:border-[var(--primary)]"
            >
              <span class="flex items-center gap-1 text-xs text-muted-foreground">
                {getUiText(props.lang, "nextPage")}
                <ArrowRightIcon class="size-3" />
              </span>
              <span class="text-sm font-medium text-foreground">{props.nextTitle}</span>
            </a>
          </Show>
        </nav>
      </Show>
    </article>
  );
}
