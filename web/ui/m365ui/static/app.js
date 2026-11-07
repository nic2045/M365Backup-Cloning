// Small progressive enhancements (ADR 0011). The pages work without this file.
(function () {
  "use strict";
  document.documentElement.classList.add("js");

  function init() {
    // Narrow screens: the menu folds behind a button (aria-expanded tells the state).
    var button = document.querySelector(".menu-toggle");
    var menu = document.getElementById("side-menu");
    if (button && menu) {
      menu.setAttribute("data-open", "false");
      var set = function (open) {
        button.setAttribute("aria-expanded", open ? "true" : "false");
        menu.setAttribute("data-open", open ? "true" : "false");
      };
      button.addEventListener("click", function () { set(button.getAttribute("aria-expanded") !== "true"); });
      document.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && button.getAttribute("aria-expanded") === "true") { set(false); button.focus(); }
      });
    }
    localTimes(document);
  }

  // Times come in UTC from the server; show them in the local time of the browser.
  // The exact value stays in the datetime and title attributes.
  function localTimes(root) {
    var format;
    try {
      format = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
    } catch (e) { return; }
    root.querySelectorAll("time[data-local]").forEach(function (t) {
      var d = new Date(t.getAttribute("datetime"));
      if (!isNaN(d.getTime())) { t.textContent = format.format(d); }
    });
  }

  document.addEventListener("htmx:afterSwap", function (e) { localTimes(e.target); });
  if (document.readyState === "loading") { document.addEventListener("DOMContentLoaded", init); } else { init(); }
})();
