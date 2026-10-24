// Single-window mode (Settings → Interface; always on Android): the app
// window loads index.html?mode=single and shows every page in a sidebar.
// Overlay windows (floating captions and dictation) load without it.
export const singleWindow = new URLSearchParams(window.location.search).get("mode") === "single";
