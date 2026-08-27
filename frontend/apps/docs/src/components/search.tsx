// Docs search — static index + client-side matching.
// Index files are emitted to public/search/<lang>.json by build-source.mjs
// and fetched at runtime; tokenization preserves CJK recall (the Fumadocs
// server route used char-level tokenizers for zh/ja — kept here).
import { createEffect, createSignal, For, Show } from "solid-js";
import { SearchIcon } from "~/components/icons";
import { useTheme } from "~/components/theme";
import { getUiText } from "~/lib/translations";
import type { Lang } from "~/lib/i18n";
import { DOCS_BASE_PATH } from "~/lib/locale-link";
import type { SearchEntry } from "~/lib/source";

function tokenize(raw: string): string[] {
  const tokens: string[] = [];
  const regex = /[々぀-ヿ㐀-䶿一-鿿]|[A-Za-z0-9]+/g;
  const lower = raw.toLowerCase();
  let match: RegExpExecArray | null;
  while ((match = regex.exec(lower)) !== null) tokens.push(match[0]);
  return tokens;
}

function score(query: string, entry: SearchEntry): number {
  const q = query.toLowerCase();
  if (entry.title.toLowerCase().includes(q)) return 100;
  if (entry.description.toLowerCase().includes(q)) return 60;
  const qt = tokenize(query);
  const text = entry.text.toLowerCase();
  let hits = 0;
  for (const t of qt) if (text.includes(t)) hits++;
  return hits > 0 ? 20 + hits : 0;
}

export function SearchDialog(props: { lang: Lang; open: boolean; onClose: () => void }) {
  const [query, setQuery] = createSignal("");
  const [results, setResults] = createSignal<SearchEntry[]>([]);
  const { theme } = useTheme();
  let indexCache: SearchEntry[] | null = null;

  createEffect(() => {
    if (!props.open) return;
    setQuery("");
    setResults([]);
    if (indexCache) return;
    fetch(DOCS_BASE_PATH + "/search/" + props.lang + ".json")
      .then((r) => r.json())
      .then((data: SearchEntry[]) => {
        indexCache = data;
        runSearch("");
      })
      .catch(() => {});
  });

  const runSearch = (q: string) => {
    if (!q.trim()) {
      setResults([]);
      return;
    }
    const all = indexCache ?? [];
    const scored = all
      .map((e) => ({ e, s: score(q, e) }))
      .filter((x) => x.s > 0)
      .sort((a, b) => b.s - a.s)
      .slice(0, 20)
      .map((x) => x.e);
    setResults(scored);
  };

  const onInput = (v: string) => {
    setQuery(v);
    runSearch(v);
  };

  return (
    <Show when={props.open}>
      <div
        class="fixed inset-0 z-[100] bg-black/40 backdrop-blur-[2px]"
        onClick={props.onClose}
        role="presentation"
      />
      <div class="fixed inset-x-0 top-[12vh] z-[101] mx-auto w-[min(36rem,calc(100vw-2rem))] rounded-lg border border-border bg-popover shadow-2xl">
        <div class="flex items-center gap-2 border-b border-border px-4">
          <SearchIcon class="size-4 shrink-0 text-muted-foreground" />
          <input
            value={query()}
            onInput={(e) => onInput(e.currentTarget.value)}
            onKeyDown={(e) => {
              if (e.key === "Escape") props.onClose();
            }}
            placeholder={getUiText(props.lang, "search")}
            autofocus
            class="h-12 w-full bg-transparent text-sm text-foreground outline-none placeholder:text-muted-foreground"
          />
        </div>
        <div class="max-h-[50vh] overflow-y-auto p-2">
          <Show
            when={results().length > 0}
            fallback={
              query().trim() ? (
                <p class="px-3 py-6 text-center text-sm text-muted-foreground">
                  {getUiText(props.lang, "searchNoResult")}
                </p>
              ) : (
                <p class="px-3 py-6 text-center text-sm text-muted-foreground">
                  {getUiText(props.lang, "search")}…
                </p>
              )
            }
          >
            <For each={results()}>
              {(r) => (
                <a
                  href={DOCS_BASE_PATH + r.url}
                  onClick={props.onClose}
                  class="block rounded-[4px] px-3 py-2.5 transition-colors hover:bg-accent"
                >
                  <div class="text-sm font-medium text-foreground">{r.title}</div>
                  <Show when={r.description}>
                    <div class="mt-0.5 line-clamp-1 text-xs text-muted-foreground">{r.description}</div>
                  </Show>
                </a>
              )}
            </For>
          </Show>
        </div>
      </div>
    </Show>
  );
}
