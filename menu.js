// Closes the hamburger menu on a click outside it, on Escape, and after following a link on the same page.
const menu = document.querySelector(".menu");
if (menu) {
  document.addEventListener("click", (e) => { if (menu.open && !menu.contains(e.target)) menu.open = false; });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && menu.open) { menu.open = false; menu.querySelector("summary").focus(); } });
  menu.querySelector(".menu-panel").addEventListener("click", (e) => { if (e.target.closest("a")) menu.open = false; });
}
