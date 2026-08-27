import { createSignal, For, Show, type Accessor } from "solid-js";
import type { Lang } from "~/lib/i18n";
import type { TreeNode } from "~/lib/source";
import { toDocsHref } from "~/lib/locale-link";

// GitHub mark (inlined SVG — lucide dropped the brand icon). Matches the
// original layout.config.tsx path.
function GitHubMark() {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" class="size-[1em]" fill="currentColor">
      <path d="M8 0C3.58 0 0 3.58 0 8a8 8 0 0 0 5.47 7.59c.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2 .37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82A7.65 7.65 0 0 1 8 4.84c.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z" />
    </svg>
  );
}

// 1Person asterisk mark (matches packages/ui AppIcon clip-path).
const MULTICA_CLIP = "polygon(45% 62.1%, 45% 100%, 55% 100%, 55% 62.1%, 81.8% 88.9%, 88.9% 81.8%, 62.1% 55%, 100% 55%, 100% 45%, 62.1% 45%, 88.9% 18.2%, 81.8% 11.1%, 55% 37.9%, 55% 0%, 45% 0%, 45% 37.9%, 18.2% 11.1%, 11.1% 18.2%, 37.9% 45%, 0% 45%, 0% 55%, 37.9% 55%, 11.1% 81.8%, 18.2% 88.9%)";

function PersonMark() {
  return (
    <span class="inline-block size-[1em]" aria-hidden="true">
      <span class="block size-full bg-current" style={{ "clip-path": MULTICA_CLIP }} />
    </span>
  );
}

function ExternalLink(props: { href: string; children?: any; icon?: any }) {
  return (
    <a
      href={props.href}
      target="_blank"
      rel="noreferrer"
      class="inline-flex items-center gap-1 text-sm text-foreground/80 no-underline transition-colors hover:text-foreground"
    >
      {props.icon}
      {props.children}
      <svg viewBox="0 0 16 16" class="size-3 translate-y-px text-muted-foreground/60" fill="none" stroke="currentColor" stroke-width="1.5">
        <path d="M6 3h7v7M13 3L5 11M10 8v5H3V6h5" />
      </svg>
    </a>
  );
}

function TreeItems(props: {
  nodes: TreeNode[];
  currentKey: string | null;
  openFolders: Accessor<Set<string>>;
  toggleFolder: (key: string) => void;
  depth: number;
}) {
  return (
    <ul class={"space-y-0.5 " + (props.depth > 0 ? "ml-3 border-l border-border/60 pl-3" : "")}>
      <For each={props.nodes}>
        {(node) => (
          <Show
            when={node.type === "separator"}
            fallback={
              <Show
                when={node.type === "folder"}
                fallback={
                  <li>
                    <a
                      href={toDocsHref((node as any).url)}
                      class={
                        "block rounded-[4px] px-2.5 py-1.5 text-sm no-underline transition-colors " +
                        (props.currentKey === (node as any).key
                          ? "bg-accent font-medium text-accent-foreground"
                          : "text-foreground/80 hover:bg-accent/60 hover:text-foreground")
                      }
                    >
                      {(node as any).title}
                    </a>
                  </li>
                }
              >
                <li>
                  <div
                    class="flex cursor-pointer items-center gap-1.5 rounded-[4px] px-2.5 py-1.5 text-sm font-medium text-foreground/90 hover:bg-accent/60"
                    onClick={() => props.toggleFolder((node as any).key)}
                  >
                    <span
                      class="text-[0.6rem] text-muted-foreground transition-transform"
                      style={{
                        transform: props.openFolders().has((node as any).key) ? "rotate(90deg)" : "none",
                      }}
                    >
                      ▸
                    </span>
                    {(node as any).title}
                  </div>
                  <Show when={props.openFolders().has((node as any).key)}>
                    <TreeItems
                      nodes={(node as any).children ?? []}
                      currentKey={props.currentKey}
                      openFolders={props.openFolders}
                      toggleFolder={props.toggleFolder}
                      depth={props.depth + 1}
                    />
                  </Show>
                </li>
              </Show>
            }
          >
            <li class="px-2.5 pb-1 pt-3 text-[0.6875rem] font-semibold uppercase tracking-[0.1em] text-muted-foreground">
              {(node as any).title}
            </li>
          </Show>
        )}
      </For>
    </ul>
  );
}

export function Sidebar(props: {
  nodes: TreeNode[];
  lang: Lang;
  currentKey: string | null;
  footer: any;
}) {
  // Folders start fully expanded (matches Fumadocs default); users may
  // collapse them. SSR and first hydration agree because the initial set is
  // derived purely from the tree, not from side effects.
  const allFolders = new Set<string>();
  (function collect(nodes: TreeNode[]) {
    for (const n of nodes) {
      if (n.type === "folder") {
        allFolders.add(n.key);
        collect(n.children ?? []);
      }
    }
  })(props.nodes);

  const [open, setOpen] = createSignal<Set<string>>(allFolders);

  const toggleFolder = (key: string) => {
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  return (
    <nav class="flex h-full flex-col overflow-y-auto px-3 py-4" aria-label="Docs navigation">
      <TreeItems
        nodes={props.nodes}
        currentKey={props.currentKey}
        openFolders={open}
        toggleFolder={toggleFolder}
        depth={0}
      />
      <div class="mt-6 border-t border-border/60 pt-4">
        <div class="space-y-2.5 px-2.5">
          <ExternalLink href="https://github.com/1person-ai/1person" icon={<GitHubMark />}>
            GitHub
          </ExternalLink>
          <ExternalLink href="https://1person.ai" icon={<PersonMark />}>
            1Person
          </ExternalLink>
        </div>
      </div>
      <div class="mt-auto pt-6">{props.footer}</div>
    </nav>
  );
}

