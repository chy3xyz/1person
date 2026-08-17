import { Meta, Title } from "@solidjs/meta";
import { Show, createComponent } from "solid-js";
import { useParams } from "@solidjs/router";
import { LANGUAGES, asLang, DEFAULT_LANGUAGE, type Lang } from "~/lib/i18n";
import { getPageWithFallback, getPageComponentSync, getTree } from "~/lib/source";
import { DocsLayout } from "~/components/layout/docs-layout";
import { DocsPage } from "~/components/layout/docs-page";
import { DocsLocaleProvider } from "~/components/locale-link";
import { DocsHero } from "~/components/hero";
import { Byline } from "~/components/editorial";
import { homeCopy } from "~/lib/translations";
import { docsAlternates } from "~/lib/site";

// Single catch-all drives every docs route except "/" (handled by index.tsx):
//   /agents            -> en page "agents"
//   /zh                -> zh landing
//   /zh/developers/... -> zh nested page
// The first segment is a locale prefix only when it is one of the
// non-default languages (en URLs are prefix-free).
export default function DocRoute() {
  const params = useParams<{ path?: string }>();
  // Router 1.0 may deliver rest params as a string ("a/b") or as an array;
  // normalize both.
  const segments = (): string[] => {
    const raw: string | string[] | undefined = params.path as string | string[] | undefined;
    if (raw == null) return [];
    if (Array.isArray(raw)) return raw;
    return raw.split("/");
  };
  const lang = () => {
    const first = segments()[0];
    if (first && LANGUAGES.includes(first as (typeof LANGUAGES)[number]) && first !== DEFAULT_LANGUAGE) {
      return first as Lang;
    }
    return DEFAULT_LANGUAGE;
  };
  const slug = () => {
    const segs = segments();
    return lang() === DEFAULT_LANGUAGE ? segs : segs.slice(1);
  };
  const page = () => getPageWithFallback(lang(), slug());
  const prevTitle = () => {
    const prev = page()?.prev;
    return prev ? prev.split("/").filter(Boolean).join(" / ") : null;
  };
  const nextTitle = () => {
    const next = page()?.next;
    return next ? next.split("/").filter(Boolean).join(" / ") : null;
  };
  const alternates = () => docsAlternates(slug());

  const isLanding = () => slug().length === 0;

function getTitle(page: ReturnType<typeof getPageWithFallback>): string {
  return page?.title ? page.title + " | 1Person Docs" : "1Person Docs";
}
  const copy = () => homeCopy[lang()];
  const MDX = () => {
    const p = page();
    return p ? getPageComponentSync(p) : undefined;
  };

  return (
    <>
      <Title>{getTitle(page())}</Title>
      <Meta name="description" content={page()?.description ?? "Documentation for 1Person"} />
      {Object.entries(alternates().languages).map(([hreflang, href]) => (
        <link rel="alternate" hreflang={hreflang} href={href} />
      ))}
      <DocsLayout
        lang={lang()}
        nodes={getTree(lang())}
        currentKey={page()?.slugKey ?? null}
        prev={page()?.prev ?? null}
        next={page()?.next ?? null}
        prevTitle={prevTitle()}
        nextTitle={nextTitle()}
        flat={isLanding()}
      >
        <Show when={page()} fallback={<NotFoundInline />}>
          <DocsLocaleProvider lang={page()!.lang}>
            <DocsPage
              lang={lang()}
              title={isLanding() ? undefined : page()!.title}
              description={page()!.description}
              prev={page()?.prev ?? null}
              next={page()?.next ?? null}
              prevTitle={prevTitle()}
              nextTitle={nextTitle()}
            >
              {isLanding() ? (
                <>
                  <DocsHero
                    eyebrow={copy().eyebrow}
                    title={
                      <>
                        {copy().titleLead}
                        <em class="font-medium not-italic text-[var(--primary)]">{copy().titleAccent}</em>
                      </>
                    }
                    subtitle={page()!.description}
                  />
                  <Byline items={[...copy().byline]} />
                </>
              ) : null}
              <Show when={MDX()} fallback={null}>
                {(C) => createComponent(C as any, {})}
              </Show>
            </DocsPage>
          </DocsLocaleProvider>
        </Show>
      </DocsLayout>
    </>
  );
}


function NotFoundInline() {
  return (
    <div class="py-20 text-center">
      <p class="docs-title font-[family-name:var(--font-serif)] text-5xl text-foreground">404</p>
      <p class="mt-3 text-muted-foreground">Page not found</p>
      <a href="/docs" class="mt-6 inline-block text-sm text-[var(--primary)] no-underline hover:underline">
        Back to docs
      </a>
    </div>
  );
}
