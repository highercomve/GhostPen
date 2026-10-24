import { lazy, Suspense, useEffect, useState } from "react";
import Menu from "./Menu";
import Shell from "./Shell";
import { singleWindow } from "./mode";

// Each window loads index.html at its own route; the other pages are split into
// their own chunks, so a window parses only the code it shows (the menu, shown
// on every hotkey, stays in the main bundle).
const Settings = lazy(() => import("./Settings"));
const Playground = lazy(() => import("./Playground"));
const Captions = lazy(() => import("./Captions"));
const Dictation = lazy(() => import("./Dictation"));
const Summary = lazy(() => import("./Summary"));
const Meetings = lazy(() => import("./Meetings"));

function route(): string {
  // "#/settings" → "/settings", default "/"
  return window.location.hash.replace(/^#/, "") || "/";
}

function Page({ path }: { path: string }) {
  if (path.startsWith("/settings")) return <Settings />;
  if (path.startsWith("/playground")) return <Playground />;
  if (path.startsWith("/captions")) return <Captions />;
  if (path.startsWith("/dictation")) return <Dictation />;
  if (path.startsWith("/summary")) return <Summary />;
  if (path.startsWith("/meetings")) return <Meetings />;
  return <Menu />; // "/" and "/actions"
}

export default function App() {
  const [path, setPath] = useState(route());

  useEffect(() => {
    const onHash = () => setPath(route());
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  if (singleWindow) return <Shell path={path} />;
  return (
    <Suspense fallback={null}>
      <Page path={path} />
    </Suspense>
  );
}
