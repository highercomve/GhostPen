import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";
// Single-window mode: its styles (single.css) all sit under this class, so the
// separate windows keep their own look.
import "./single.css";
// Android: its own look (android.css), all under this class.
import "./android.css";
import { singleWindow } from "./mode";

if (singleWindow) document.documentElement.classList.add("single-window");
if (/Android/i.test(navigator.userAgent)) document.documentElement.classList.add("platform-android");

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
