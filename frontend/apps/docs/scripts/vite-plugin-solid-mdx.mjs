// Custom Vite plugin: compile content/docs/*.mdx with @mdx-js/mdx into a
// plain-JS Solid module (jsx() calls from solid-js/jsx-runtime). We write our
// own transform instead of @mdx-js/rollup because the latter's output is not
// transformed correctly under Rolldown (Vite 8) — the JSX it emits is parsed
// as plain JS and fails.
import { compile } from "@mdx-js/mdx";
import remarkGfm from "remark-gfm";
import rehypeSlug from "rehype-slug";
import rehypeHighlight from "rehype-highlight";

export function solidMdx() {
  return {
    name: "solid-docs-mdx",
    enforce: "pre",
    async transform(code, id) {
      if (!id.endsWith(".mdx")) return null;
      const compiled = await compile(code, {
        // solid-js/jsx-runtime is types-only; route through our shim
        jsxImportSource: "@mdx-runtime",
        providerImportSource: "solid-mdx",
        remarkPlugins: [remarkGfm],
        rehypePlugins: [rehypeSlug, rehypeHighlight],
        // Keep development metadata out; output plain JS (no JSX) so
        // Rolldown's native parser accepts it.
        development: false,
      });
      return { code: String(compiled), map: null };
    },
  };
}
