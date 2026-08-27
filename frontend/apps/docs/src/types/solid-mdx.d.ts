declare module "solid-mdx" {
  import type { ParentComponent, Context } from "solid-js";

  export const MDXContext: Context<Record<string, unknown> | undefined>;
  export const MDXProvider: ParentComponent<{ components?: Record<string, unknown> }>;
  export function useMDXComponents(): Record<string, unknown>;
}
