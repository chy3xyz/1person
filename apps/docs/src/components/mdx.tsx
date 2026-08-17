import type { JSX } from "solid-js";
import { Callout } from "~/components/callout";
import { Mermaid } from "~/components/mermaid";
import { ArchitectureDiagram } from "~/components/architecture-diagram";
import { NumberedCard, NumberedCards, NumberedSteps, Step } from "~/components/editorial";
import { LocaleLink } from "~/components/locale-link";

/**
 * Component map injected via solid-mdx's MDXProvider. `a` is overridden so
 * every internal link in MDX content carries the locale + /docs prefix.
 */
export const mdxComponents: Record<string, (props: any) => JSX.Element> = {
  a: LocaleLink,
  Callout,
  Mermaid,
  ArchitectureDiagram,
  NumberedCard,
  NumberedCards,
  NumberedSteps,
  Step,
};
