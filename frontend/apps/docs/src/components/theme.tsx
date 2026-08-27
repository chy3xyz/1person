// Theme provider — minimal, no external deps.
import { createContext, createEffect, createSignal, useContext, type JSX, type ParentProps } from "solid-js";

type Theme = "light" | "dark" | "system";
const ThemeContext = createContext<{ theme: () => Theme; setTheme: (t: Theme) => void }>();

export function ThemeProvider(props: ParentProps) {
  const [theme, setThemeState] = createSignal<Theme>(
    (typeof localStorage !== "undefined" && (localStorage.getItem("docs-theme") as Theme)) || "system",
  );
  const setTheme = (t: Theme) => {
    setThemeState(t);
    if (typeof localStorage !== "undefined") localStorage.setItem("docs-theme", t);
  };
  createEffect(() => {
    const t = theme();
    const dark = t === "dark" || (t === "system" && window.matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.classList.toggle("dark", dark);
  });
  return <ThemeContext.Provider value={{ theme, setTheme }}>{props.children}</ThemeContext.Provider>;
}

export function useTheme() {
  const ctx = useContext(ThemeContext);
  if (!ctx) throw new Error("useTheme must be used within ThemeProvider");
  return ctx;
}
