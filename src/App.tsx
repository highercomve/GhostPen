import { useEffect, useState } from "react";
import Menu from "./Menu";
import Settings from "./Settings";
import Playground from "./Playground";

function route(): string {
  // "#/settings" → "/settings", default "/"
  return window.location.hash.replace(/^#/, "") || "/";
}

export default function App() {
  const [path, setPath] = useState(route());

  useEffect(() => {
    const onHash = () => setPath(route());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  if (path.startsWith("/settings")) return <Settings />;
  if (path.startsWith("/playground")) return <Playground />;
  return <Menu />;
}
