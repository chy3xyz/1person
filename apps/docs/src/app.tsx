import "./global.css";
import { Router } from "@solidjs/router";
import { FileRoutes } from "@solidjs/start/router";
import { Suspense } from "solid-js";
import { MetaProvider } from "@solidjs/meta";
import { MDXProvider } from "solid-mdx";
import { mdxComponents } from "~/components/mdx";
import { ThemeProvider } from "~/components/theme";

export default function App() {
  return (
    <MetaProvider>
      <MDXProvider components={mdxComponents}>
        <ThemeProvider>
          <Router root={(props) => <Suspense>{props.children}</Suspense>}>
            <FileRoutes />
          </Router>
        </ThemeProvider>
      </MDXProvider>
    </MetaProvider>
  );
}
