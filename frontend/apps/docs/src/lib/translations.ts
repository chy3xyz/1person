import type { Lang } from "~/lib/i18n";

// Docs UI strings per locale (search, TOC, prev/next, footer). English uses
// inline defaults; overrides below. Mirrors the Fumadocs translations that
// the Next implementation carried.
export type UiTranslations = {
  search: string;
  searchNoResult: string;
  toc: string;
  lastUpdate: string;
  chooseLanguage: string;
  nextPage: string;
  previousPage: string;
  chooseTheme: string;
  editOnGithub: string;
  menu: string;
};

export const uiTranslations: Partial<Record<Lang, Partial<UiTranslations>>> = {
  zh: {
    search: "搜索",
    searchNoResult: "没有找到结果",
    toc: "本页目录",
    lastUpdate: "最后更新于",
    chooseLanguage: "选择语言",
    nextPage: "下一页",
    previousPage: "上一页",
    chooseTheme: "切换主题",
    editOnGithub: "在 GitHub 上编辑",
    menu: "菜单",
  },
  ko: {
    search: "검색",
    searchNoResult: "결과가 없습니다",
    toc: "이 페이지에서",
    lastUpdate: "마지막 업데이트",
    chooseLanguage: "언어 선택",
    nextPage: "다음 페이지",
    previousPage: "이전 페이지",
    chooseTheme: "테마 변경",
    editOnGithub: "GitHub에서 편집",
    menu: "메뉴",
  },
  ja: {
    search: "検索",
    searchNoResult: "結果が見つかりません",
    toc: "このページの内容",
    lastUpdate: "最終更新",
    chooseLanguage: "言語を選択",
    nextPage: "次のページ",
    previousPage: "前のページ",
    chooseTheme: "テーマを変更",
    editOnGithub: "GitHub で編集",
    menu: "メニュー",
  },
};

export function getUiText(lang: Lang, key: keyof UiTranslations): string {
  const overrides = uiTranslations[lang];
  if (overrides && overrides[key]) return overrides[key] as string;
  const defaults: UiTranslations = {
    search: "Search",
    searchNoResult: "No results found",
    toc: "On this page",
    lastUpdate: "Last updated",
    chooseLanguage: "Choose language",
    nextPage: "Next",
    previousPage: "Previous",
    chooseTheme: "Change theme",
    editOnGithub: "Edit on GitHub",
    menu: "Menu",
  };
  return defaults[key];
}

// Display names shown in the language switcher.
export const localeLabels: Record<Lang, string> = {
  en: "English",
  zh: "简体中文",
  ko: "한국어",
  ja: "日本語",
};

// Copy for the welcome page (Hero + Byline). Pages are translated as MDX;
// this dict only carries TSX-rendered chrome above the MDX body.
export const homeCopy = {
  en: {
    eyebrow: "1Person Docs",
    titleLead: "Humans and agents,",
    titleAccent: "in one place.",
    byline: ["Getting started", "Updated April 2026", "6 min read"],
  },
  zh: {
    eyebrow: "1Person 文档",
    titleLead: "人与智能体，",
    titleAccent: "共处一方。",
    byline: ["开始使用", "2026 年 4 月更新", "阅读约 6 分钟"],
  },
  ko: {
    eyebrow: "1Person 문서",
    titleLead: "사람과 에이전트,",
    titleAccent: "한곳에서.",
    byline: ["시작하기", "2026년 4월 업데이트", "약 6분 읽기"],
  },
  ja: {
    eyebrow: "1Person ドキュメント",
    titleLead: "人とエージェントが、",
    titleAccent: "一つの場所に。",
    byline: ["はじめに", "2026年4月更新", "約6分で読めます"],
  },
} as const satisfies Record<Lang, unknown>;
