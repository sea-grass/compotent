export const css = clientCss();
export const js = clientJs();
export const html = render;

function clientCss() {
  return `
  .my-dropdown {
border: 1px solid black;
padding: 0.5em;

  }

  .my-dropdown[data-open="false"] .items {
  display: none; 
}`;
}
function clientJs() {
  return `Array.from(document.querySelectorAll(".my-dropdown")).forEach(initDropdown);

function toggleNav(el) {
  return () => {
    if (el.dataset.open === "false") {
    el.dataset.open = "true";
    } else {
    el.dataset.open = "false";
    }
  };
}

function initDropdown(el) {
  const button = el.querySelector("[data-toggle]");
  if (!button) return;

  button.addEventListener("click", toggleNav(el));
}`;
}

export function render(data) {
  return `<div class="my-dropdown" data-open="false">
  <button class="button" data-toggle>Toggle</button>
  <ul class="items">
    ${navItem({ href: "/", text: data.title })}
    ${data.navItems.map(navItem).join("\n")}
  </ul>
</div>`;
}

function navItem(data) {
  return `<li><a href="${data.href}">${data.text}</a></li>`;
}
