import type { ParentProps } from "solid-js";

const LABELS: Record<string, string> = {
  info: "NOTE",
  warning: "WARNING",
  error: "ERROR",
  success: "SUCCESS",
};

/**
 * Callout — editorial 2px accent bar + soft accent wash (Solid port of the
 * Fumadocs component; styled via the .callout classes in global.css).
 */
export function Callout(props: ParentProps<{ type?: string; title?: string }>) {
  const type = () => props.type ?? "info";
  return (
    <div class={"callout callout-" + type()} role="note">
      <p class="callout-label">{props.title ?? LABELS[type()] ?? "NOTE"}</p>
      <div class="callout-body">{props.children}</div>
    </div>
  );
}
