import { Meta, Title } from "@solidjs/meta";
import { DEFAULT_LANGUAGE } from "~/lib/i18n";
import { getPage, getPageComponentSync, getTree } from "~/lib/source";
import { DocsLayout } from "~/components/layout/docs-layout";
import { DocsLocaleProvider } from "~/components/locale-link";
import { DocsPage } from "~/components/layout/docs-page";
import { DocsHero } from "~/components/hero";
import { Byline } from "~/components/editorial";
import { homeCopy } from "~/lib/translations";
import { docsAlternates } from "~/lib/site";

// Default-language home (/docs). zh/ko/ja land on /docs/<lang> (see
// routes/[lang]/index.tsx). Same visual: editorial hero + byline + MDX body.
export default function Home() {
  const lang = DEFAULT_LANGUAGE;
  const page = getPage(lang, [])!;
  const copy = homeCopy[lang];
  const alternates = docsAlternates([]);
  const MDX = getPageComponentSync(page);

  return (
    <>
      <Title>1Person Docs</Title>
      <Meta name="description" content={page.description || "Documentation for 1Person"} />
      {Object.entries(alternates.languages).map(([hreflang, href]) => (
        <link rel="alternate" hreflang={hreflang} href={href} />
      ))}
      <DocsLayout lang={lang} nodes={getTree(lang)} currentKey={null} flat>
        <DocsLocaleProvider lang={lang}>
          <DocsPage lang={lang}>
            <DocsHero
              eyebrow={copy.eyebrow}
              title={
                <>
                  {copy.titleLead}
                  <em class="font-medium not-italic text-[var(--primary)]">{copy.titleAccent}</em>
                </>
              }
              subtitle={page.description}
            />
            <Byline items={[...copy.byline]} />
            {MDX ? <MDX /> : null}
          </DocsPage>
        </DocsLocaleProvider>
      </DocsLayout>
    </>
  );
}
