import { createContext, useContext, type JSX, type ParentProps } from "solid-js";
import { DEFAULT_LANGUAGE, type Lang } from "~/lib/i18n";
import { prefixLocale, DOCS_BASE_PATH } from "~/lib/locale-link";

const DocsLocaleContext = createContext<Lang>(DEFAULT_LANGUAGE);

/** Wraps the rendered MDX subtree so descendant links know the page locale. */
export function DocsLocaleProvider(props: ParentProps<{ lang: Lang }>) {
  return (
    <DocsLocaleContext.Provider value={props.lang}>
      {props.children}
    </DocsLocaleContext.Provider>
  );
}

export function useDocsLocale(): Lang {
  return useContext(DocsLocaleContext);
}

/**
 * Drop-in replacement for the MDX-rendered `<a>` element: prefixes internal
 * links with the active locale + /docs base, so navigation stays in-locale.
 */
export function LocaleLink(props: JSX.AnchorHTMLAttributes<HTMLAnchorElement> & { href?: string }) {
  const lang = useDocsLocale();
  const { href } = props;
  const rest = { ...props };
  delete rest.href;
  if (!href) return <a {...rest} />;
  const final = prefixLocale(href, lang);
  return <a href={final} {...rest} />;
}
