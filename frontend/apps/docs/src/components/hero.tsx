import type { JSX } from "solid-js";

/**
 * DocsHero — editorial showpiece header (Solid port). Escapes prose scope to
 * run its own type scale. Title accepts arbitrary nodes for brand emphasis.
 */
export function DocsHero(props: {
  eyebrow?: string;
  title: JSX.Element;
  subtitle?: JSX.Element;
}) {
  return (
    <section class="not-prose mb-7 pt-2">
      {props.eyebrow ? (
        <p class="mb-5 text-[0.6875rem] font-semibold uppercase tracking-[0.1em] text-muted-foreground">
          {props.eyebrow}
        </p>
      ) : null}
      <h1 class="mb-5 font-[family-name:var(--font-serif)] text-[2.25rem] font-normal leading-[1.05] tracking-[-0.025em] text-foreground sm:text-[2.75rem]">
        {props.title}
      </h1>
      {props.subtitle ? (
        <p class="max-w-[36rem] font-[family-name:var(--font-serif)] text-[1.25rem] leading-[1.5] tracking-[-0.005em] text-[oklch(from_var(--foreground)_calc(l+0.06)_c_h)]">
          {props.subtitle}
        </p>
      ) : null}
    </section>
  );
}

export function DocsFeatureGrid(props: { children?: any }) {
  return (
    <div class="not-prose my-8 grid grid-cols-1 gap-3 md:grid-cols-3">
      {props.children}
    </div>
  );
}

export function DocsFeatureCard(props: {
  icon?: any;
  title: string;
  description: string;
  href: string;
}) {
  return (
    <a
      href={props.href}
      class="group flex flex-col gap-3 rounded-[4px] border border-border bg-card p-5 no-underline transition-all hover:border-[var(--primary)]"
    >
      <div class="flex size-9 items-center justify-center text-[var(--accent-foreground)] [&_svg]:size-[20px]">
        {props.icon}
      </div>
      <div class="flex flex-col gap-1.5">
        <span class="font-[family-name:var(--font-serif)] text-[1.0625rem] font-medium tracking-[-0.01em] text-foreground">
          {props.title}
        </span>
        <p class="text-sm leading-[1.55] text-muted-foreground">{props.description}</p>
      </div>
    </a>
  );
}
