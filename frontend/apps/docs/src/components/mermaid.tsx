import { createEffect, createSignal, createUniqueId, onCleanup } from "solid-js";
import { useTheme } from "~/components/theme";

/**
 * Client-side Mermaid diagram renderer (Solid port). Dynamic-imports mermaid
 * so it only loads on pages that use it. Re-renders when the theme flips.
 *
 * Themed from live CSS tokens via getComputedStyle — tracks light/dark mode
 * and future token changes without a rebuild (see original implementation).
 */
export function Mermaid(props: { chart: string }) {
  const { theme } = useTheme();
  const id = createUniqueId();
  const [svg, setSvg] = createSignal<string | null>(null);
  const [error, setError] = createSignal<string | null>(null);

  createEffect(() => {
    theme(); // re-render on theme flip
    let cancelled = false;

    void import("mermaid").then(({ default: mermaid }) => {
      const css = getComputedStyle(document.documentElement);
      const canvas = document.createElement("canvas");
      canvas.width = 1;
      canvas.height = 1;
      const ctx = canvas.getContext("2d", { willReadFrequently: true });

      const v = (name: string, fallback: string) => {
        const raw = css.getPropertyValue(name).trim();
        if (!raw || !ctx) return fallback;
        ctx.fillStyle = "#000";
        ctx.fillStyle = raw;
        ctx.fillRect(0, 0, 1, 1);
        const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data;
        return `rgb(${r}, ${g}, ${b})`;
      };

      const brand = v("--brand", "#3b82f6");
      const brandFg = v("--brand-foreground", "#ffffff");
      const background = v("--background", "#ffffff");
      const foreground = v("--foreground", "#111111");
      const muted = v("--muted", "#f5f5f5");
      const mutedFg = v("--muted-foreground", "#6b7280");
      const border = v("--border", "#e5e5e5");
      const accent = v("--accent", muted);

      mermaid.initialize({
        startOnLoad: false,
        theme: "base",
        securityLevel: "strict",
        fontFamily: "inherit",
        themeVariables: {
          background,
          mainBkg: background,
          primaryColor: muted,
          primaryTextColor: foreground,
          primaryBorderColor: border,
          secondaryColor: accent,
          secondaryTextColor: foreground,
          secondaryBorderColor: border,
          tertiaryColor: background,
          tertiaryTextColor: foreground,
          tertiaryBorderColor: border,
          lineColor: mutedFg,
          textColor: foreground,
          edgeLabelBackground: background,
          labelBackground: background,
          clusterBkg: accent,
          clusterBorder: border,
          titleColor: foreground,
          noteBkgColor: muted,
          noteTextColor: foreground,
          noteBorderColor: border,
          activeTaskBkgColor: brand,
          activeTaskBorderColor: brand,
          altBackground: muted,
          actorBkg: muted,
          actorBorder: border,
          actorTextColor: foreground,
          actorLineColor: mutedFg,
          signalColor: foreground,
          signalTextColor: foreground,
          errorBkgColor: muted,
          errorTextColor: foreground,
        },
      });

      const domId = `mermaid-${id.replace(/:/g, "")}`;
      mermaid
        .render(domId, props.chart.trim())
        .then((result: { svg: string }) => {
          if (!cancelled) {
            setSvg(result.svg);
            setError(null);
          }
        })
        .catch((err: unknown) => {
          if (!cancelled) {
            setError(err instanceof Error ? err.message : String(err));
            setSvg(null);
          }
        });
    });

    onCleanup(() => {
      cancelled = true;
    });
  });

  if (error()) {
    return (
      <pre class="my-4 rounded-md border border-destructive/40 bg-destructive/10 p-3 text-sm text-destructive">
        Mermaid error: {error()}
      </pre>
    );
  }

  if (!svg()) {
    return <div class="my-4 text-sm text-muted-foreground">Rendering diagram…</div>;
  }

  return (
    <div
      class="my-6 flex justify-center overflow-x-auto rounded-md border border-border/60 bg-muted/20 p-6 [&_.label_foreignObject>div]:!font-[inherit] [&_.nodeLabel]:!font-[inherit] [&_.edgeLabel]:!font-[inherit] [&_text]:!font-[inherit]"
      innerHTML={svg() ?? ""}
    />
  );
}
