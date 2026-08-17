// Solid jsx-runtime shim for @mdx-js/mdx output.
//
// solid-js/jsx-runtime is a types-only stub (its runtime export points at
// dist/solid.js, which does not export jsx/jsxs/Fragment). MDX compiled with
// jsxImportSource therefore cannot resolve a real jsx() implementation.
// Instead, compile MDX with jsxImportSource "@mdx-runtime" and route every
// element through solid-js's Dynamic component, which is environment-aware:
// it renders string tags (server: ssrElement, client: DOM) and function
// components alike.
import { createComponent } from "solid-js";
import { Dynamic } from "solid-js/web";

export function jsx(type: unknown, props: Record<string, unknown> | null): unknown {
  return createComponent(Dynamic, { component: type as any, ...(props ?? {}) });
}

export const jsxs = jsx;

export function Fragment(props: { children?: unknown }): unknown {
  return props.children;
}
