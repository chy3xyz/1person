import { createEffect, createSignal } from "solid-js";
import { MonitorIcon, MoonIcon, SunIcon } from "~/components/icons";
import { useTheme } from "~/components/theme";
import { DropdownMenu } from "~/components/ui/dropdown";
import { LANGUAGES } from "~/lib/i18n";
import { localeLabels } from "~/lib/translations";
import { DOCS_BASE_PATH } from "~/lib/locale-link";

// Sidebar-footer chrome: language switch (left) + theme switch (right).

function switchLocalePath(pathname: string, target: string): string {
  // pathname is the docs-internal route (no /docs prefix), starting at "/" or
  // "/<locale>/...". Default-locale URLs are prefix-less.
  const segments = pathname.split("/").filter(Boolean);
  const first = segments[0];
  const hasLocalePrefix = first && LANGUAGES.some((l) => l === first && l !== "en");
  const rest = hasLocalePrefix ? segments.slice(1) : segments;
  const prefixed = target === "en" ? rest : [target, ...rest];
  return "/" + prefixed.join("/");
}

const THEME_OPTIONS = [
  { value: "light", label: "Light", icon: () => <SunIcon class="size-4" /> },
  { value: "dark", label: "Dark", icon: () => <MoonIcon class="size-4" /> },
  { value: "system", label: "System", icon: () => <MonitorIcon class="size-4" /> },
] as const;

export function DocsSettings(props: { locale: string; pathname: string }) {
  const { theme, setTheme } = useTheme();
  const [mounted, setMounted] = createSignal(false);
  createEffect(() => {
    setMounted(true);
  });
  const activeTheme = () => (mounted() ? (theme() ?? "system") : "system");

  const handleLocaleChange = (next: string) => {
    if (next === props.locale) return;
    const internal = props.pathname.startsWith(DOCS_BASE_PATH)
      ? props.pathname.slice(DOCS_BASE_PATH.length) || "/"
      : props.pathname;
    window.location.href = DOCS_BASE_PATH + switchLocalePath(internal, next);
  };

  return (
    <div class="flex w-full items-center justify-end gap-2">
      <DropdownMenu
        align="start"
        side="top"
        trigger={(toggle, open) => (
          <button
            type="button"
            onClick={toggle}
            aria-label="Switch language"
            aria-expanded={open}
            class="inline-flex h-7 items-center gap-1.5 rounded-[4px] px-2 font-normal text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground"
          >
            {localeLabels[props.locale as keyof typeof localeLabels] ?? props.locale}
          </button>
        )}
      >
        {(close) => (
          <div class="flex flex-col">
            {LANGUAGES.map((lang) => (
              <button
                type="button"
                onClick={() => {
                  close();
                  handleLocaleChange(lang as string);
                }}
                class={
                  "flex items-center justify-between px-2.5 py-1.5 text-left text-sm rounded-[4px] transition-colors hover:bg-accent " +
                  (lang === props.locale ? "bg-accent text-accent-foreground" : "text-foreground")
                }
              >
                {localeLabels[lang as keyof typeof localeLabels]}
                {lang === props.locale ? <span class="text-xs text-[var(--primary)]">✓</span> : null}
              </button>
            ))}
          </div>
        )}
      </DropdownMenu>

      <DropdownMenu
        align="end"
        side="top"
        trigger={(toggle, open) => (
          <button
            type="button"
            onClick={toggle}
            aria-label="Switch theme"
            aria-expanded={open}
            class="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-[4px] text-muted-foreground transition-colors hover:bg-accent hover:text-accent-foreground"
          >
            {THEME_OPTIONS.find((o) => o.value === activeTheme())?.icon() ?? <MonitorIcon class="size-4" />}
          </button>
        )}
      >
        {(close) => (
          <div class="flex flex-col">
            {THEME_OPTIONS.map((opt) => (
              <button
                type="button"
                onClick={() => {
                  setTheme(opt.value);
                  close();
                }}
                class={
                  "flex items-center gap-2 px-2.5 py-1.5 text-left text-sm rounded-[4px] transition-colors hover:bg-accent " +
                  (opt.value === activeTheme() ? "bg-accent text-accent-foreground" : "text-foreground")
                }
              >
                {opt.icon()}
                {opt.label}
              </button>
            ))}
          </div>
        )}
      </DropdownMenu>
    </div>
  );
}
