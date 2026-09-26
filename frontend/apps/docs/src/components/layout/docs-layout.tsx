import { createSignal, Show, type JSX } from "solid-js";
import { useLocation } from "@solidjs/router";
import { MenuIcon, SearchIcon, XIcon } from "~/components/icons";
import type { Lang } from "~/lib/i18n";
import type { TreeNode, PageMeta } from "~/lib/source";
import { Sidebar } from "~/components/layout/sidebar";
import { Toc, type TocItem } from "~/components/layout/toc";
import { DocsSettings } from "~/components/docs-settings";
import { SearchDialog } from "~/components/search";
import { getUiText } from "~/lib/translations";
import { DOCS_BASE_PATH, toDocsHref } from "~/lib/locale-link";

const EXTERNAL_LINKS: { label: string; href: string }[] = [
  { label: "GitHub", href: "https://github.com/chy3xyz/1person" },
  { label: "1Person", href: "https://1person.xyz" },
];

export function DocsLayout(props: {
  lang: Lang;
  nodes: TreeNode[];
  currentKey: string | null;
  children: JSX.Element;
  title?: string;
  description?: string;
  toc?: TocItem[];
  prev?: string | null;
  next?: string | null;
  prevTitle?: string | null;
  nextTitle?: string | null;
  flat?: boolean;
}) {
  const location = useLocation();
  const [menuOpen, setMenuOpen] = createSignal(false);
  const [searchOpen, setSearchOpen] = createSignal(false);

  const settings = <DocsSettings locale={props.lang} pathname={location.pathname} />;

  return (
    <div class="min-h-screen">
      <header class="sticky top-0 z-40 border-b border-border/60 bg-background/85 backdrop-blur supports-[backdrop-filter]:bg-background/70">
        <div class="flex h-14 items-center gap-2 px-3 md:px-5">
          <button
            type="button"
            onClick={() => setMenuOpen((v) => !v)}
            class="inline-flex size-8 items-center justify-center rounded-[4px] text-muted-foreground hover:bg-accent md:hidden"
            aria-label={getUiText(props.lang, "menu")}
          >
            {menuOpen() ? <XIcon class="size-4" /> : <MenuIcon class="size-4" />}
          </button>
          <a href={DOCS_BASE_PATH} class="text-base font-semibold text-foreground no-underline">
            1Person Docs
          </a>
          <div class="ml-auto flex items-center gap-1.5">
            <button
              type="button"
              onClick={() => setSearchOpen(true)}
              class="hidden items-center gap-2 rounded-[4px] border border-border/70 px-2.5 py-1.5 text-sm text-muted-foreground transition-colors hover:border-border hover:bg-accent/60 sm:inline-flex"
              aria-label={getUiText(props.lang, "search")}
            >
              <SearchIcon class="size-3.5" />
              <span>{getUiText(props.lang, "search")}</span>
            </button>
            <button
              type="button"
              onClick={() => setSearchOpen(true)}
              class="inline-flex size-8 items-center justify-center rounded-[4px] text-muted-foreground hover:bg-accent sm:hidden"
              aria-label={getUiText(props.lang, "search")}
            >
              <SearchIcon class="size-4" />
            </button>
            <div class="hidden items-center gap-4 pl-3 md:flex">
              {EXTERNAL_LINKS.map((l) => (
                <a
                  href={l.href}
                  target="_blank"
                  rel="noreferrer"
                  class="text-sm text-foreground/80 no-underline transition-colors hover:text-foreground"
                >
                  {l.label}
                </a>
              ))}
            </div>
          </div>
        </div>
      </header>

      <div class="mx-auto flex w-full max-w-[var(--fd-layout-width)]">
        {/* Desktop sidebar */}
        <aside class="sticky top-14 hidden h-[calc(100vh-3.5rem)] w-64 shrink-0 border-r border-border/60 md:block">
          <Sidebar nodes={props.nodes} lang={props.lang} currentKey={props.currentKey} footer={settings} />
        </aside>

        {/* Mobile drawer */}
        <Show when={menuOpen()}>
          <div
            class="fixed inset-0 top-14 z-30 bg-black/30 md:hidden"
            onClick={() => setMenuOpen(false)}
            role="presentation"
          />
          <aside class="fixed bottom-0 left-0 top-14 z-40 w-72 overflow-y-auto border-r border-border bg-background md:hidden">
            <Sidebar
              nodes={props.nodes}
              lang={props.lang}
              currentKey={props.currentKey}
              footer={
                <div class="px-3" onClick={() => setMenuOpen(false)}>
                  {settings}
                </div>
              }
            />
          </aside>
        </Show>

        {/* Main content */}
        <main class="min-w-0 flex-1 px-4 py-8 md:px-8 md:py-10">
          <div class={"mx-auto w-full " + (props.flat ? "max-w-none" : "max-w-[var(--fd-page-width)]")}>
            {props.children}
          </div>
        </main>

        {/* TOC */}
        <aside class="sticky top-14 hidden h-[calc(100vh-3.5rem)] w-56 shrink-0 border-l border-border/60 px-4 py-8 xl:block">
          <Toc items={props.toc ?? []} lang={props.lang} />
        </aside>
      </div>

      <SearchDialog lang={props.lang} open={searchOpen()} onClose={() => setSearchOpen(false)} />
    </div>
  );
}
