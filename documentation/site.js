const root = document.documentElement;
const themeToggle = document.getElementById("theme-toggle");
const themeIcon = document.getElementById("theme-icon");
const THEME_KEY = "soleil-theme";
const media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

function storedTheme() {
  try { return localStorage.getItem(THEME_KEY); } catch (e) { return null; }
}

function saveTheme(theme) {
  try { localStorage.setItem(THEME_KEY, theme); } catch (e) {}
}

function apply(theme) {
  root.dataset.theme = theme;
  if (themeIcon) themeIcon.textContent = theme === "dark" ? "light_mode" : "dark_mode";
}

apply(root.dataset.theme === "dark" ? "dark" : "light");

if (themeToggle) {
  themeToggle.addEventListener("click", () => {
    const next = root.dataset.theme === "dark" ? "light" : "dark";
    apply(next);
    saveTheme(next);
  });
}

if (media) {
  const onSystemChange = (e) => {
    if (!storedTheme()) apply(e.matches ? "dark" : "light");
  };
  if (media.addEventListener) media.addEventListener("change", onSystemChange);
  else if (media.addListener) media.addListener(onSystemChange);
}

window.addEventListener("storage", (e) => {
  if (e.key === THEME_KEY && (e.newValue === "dark" || e.newValue === "light")) {
    apply(e.newValue);
  }
});

const snackbar = document.getElementById("snackbar");
if (snackbar) {
  let snackTimer;
  const showSnackbar = () => {
    snackbar.classList.add("show");
    clearTimeout(snackTimer);
    snackTimer = setTimeout(() => snackbar.classList.remove("show"), 3500);
  };
  ["snack-trigger", "snack-trigger-2"].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.addEventListener("click", showSnackbar);
  });
  snackbar.querySelector(".action").addEventListener("click", () => snackbar.classList.remove("show"));
}

const fab = document.querySelector("md-fab");
if (fab) {
  fab.addEventListener("click", () => {
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
}
