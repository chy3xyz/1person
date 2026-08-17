// Language config — mirrors the Fumadocs i18n setup:
// English is default with prefix-free URLs; zh/ko/ja carry a path prefix.
// Dot-suffixed sources (page.zh.mdx) are resolved by scripts/build-source.mjs.
export const LANGUAGES = ["en", "zh", "ko", "ja"] as const;
export const DEFAULT_LANGUAGE = "en" as const;

export type Lang = (typeof LANGUAGES)[number];

export function isLang(value: string): value is Lang {
  return (LANGUAGES as readonly string[]).includes(value);
}

export function asLang(value: string | undefined): Lang {
  return value && isLang(value) ? value : DEFAULT_LANGUAGE;
}
