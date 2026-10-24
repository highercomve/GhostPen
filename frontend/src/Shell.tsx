import { lazy, Suspense, useEffect, useRef, useState, type ReactNode } from "react";
import Menu from "./Menu";
import { Icon, type IconName } from "./icons";
import { listen } from "./events";
import { dictationStart, openCaptions, uiState, type UiState } from "./api";
import { SECTIONS as SETTINGS_SECTIONS } from "./settingsSections";

// Single-window mode: one app window, a sidebar on the left and the page in
// the middle (like a desktop chat app). A page stays mounted once visited, so
// a conversation, a recording or a summary survives switching pages; only the
// current one is shown. The backend moves the window to a page with
// ghostpen://navigate (the hotkey: Actions; the tray: Settings, …).
const Settings = lazy(() => import("./Settings"));
const Playground = lazy(() => import("./Playground"));
const Captions = lazy(() => import("./Captions"));
const Dictation = lazy(() => import("./Dictation"));
const Summary = lazy(() => import("./Summary"));
const Meetings = lazy(() => import("./Meetings"));

interface Section {
  route: string;
  label: string;
  icon: IconName;
  page: () => ReactNode;
  /** Captions and dictation set to float: the item opens the overlay instead. */
  floats?: (ui: UiState) => boolean;
  open?: () => void;
}

const SECTIONS: Section[] = [
  { route: "/actions", label: "Actions", icon: "proofread", page: () => <Menu /> },
  { route: "/playground", label: "Playground", icon: "chat", page: () => <Playground /> },
  { route: "/summary", label: "Summarize a link", icon: "link", page: () => <Summary /> },
  { route: "/meetings", label: "Meetings", icon: "meetings", page: () => <Meetings /> },
  {
    route: "/captions",
    label: "Captions",
    icon: "captions",
    page: () => <Captions />,
    floats: (ui) => ui.float_captions,
    open: () => void openCaptions().catch((e) => console.warn("captions:", e)),
  },
  {
    route: "/dictation",
    label: "Dictation",
    icon: "mic",
    page: () => <Dictation />,
    floats: (ui) => ui.float_dictation,
    open: () => void dictationStart().catch((e) => console.warn("dictation:", e)),
  },
];
const SETTINGS: Section = { route: "/settings", label: "Settings", icon: "settings", page: () => <Settings /> };
const ALL = [...SECTIONS, SETTINGS];

function routeOf(path: string): string {
  return ALL.find((s) => path.startsWith(s.route))?.route ?? "/actions";
}

const NARROW = "(max-width: 720px)";
/** The start page: back from any other top-level page comes here. */
const START = "/actions";

/** The app bar's title: the page, or the Settings section. */
function titleOf(route: string, path: string): string {
  if (route === SETTINGS.route) return SETTINGS_SECTIONS.find((x) => x.id === settingsSection(path))?.label ?? "Settings";
  return ALL.find((s) => s.route === route)?.label ?? "GhostPen";
}

/** The Settings section in the path ("/settings/voices" → "voices"; "ai" by default). */
function settingsSection(path: string): string {
  return path.match(/^\/settings\/(\w+)/)?.[1] ?? "ai";
}

export default function Shell({ path }: { path: string }) {
  const current = routeOf(path);
  const [ui, setUi] = useState<UiState | null>(null);
  const [visited, setVisited] = useState<string[]>([current]);
  const [narrow, setNarrow] = useState(() => window.matchMedia(NARROW).matches);
  const [collapsed, setCollapsed] = useState(false);
  const [drawer, setDrawer] = useState(false);
  // A page's own sub-page (a meeting): its title, and a back arrow in the app bar.
  const [subtitle, setSubtitle] = useState("");
  useEffect(() => {
    const on = (e: Event) => setSubtitle(String((e as CustomEvent).detail ?? ""));
    window.addEventListener("ghostpen:subtitle", on);
    return () => window.removeEventListener("ghostpen:subtitle", on);
  }, []);
  const sub = subtitle && path.split("/").length > 2 && current !== SETTINGS.route ? subtitle : "";

  // Back, Android's way (also the WebView's history, which Android's back
  // gesture walks): the drawer closes; a sub-page (a meeting) returns to its
  // list; a top-level page returns to the start page (Actions), not through
  // every page visited; from the start page the app goes to the background.
  // So: a top-level page opened from the start page is a new entry, one opened
  // from another top-level page replaces it; the open drawer is an entry too.
  const drawerEntry = useRef(false);
  const pending = useRef<string | null>(null);

  const navigate = (route: string, replace: boolean) => {
    if (replace) window.location.replace("#" + route);
    else window.location.hash = route;
  };

  const go = (route: string) => {
    const here = window.location.hash.replace(/^#/, "") || START;
    // Already there (Settings keeps its section): only the drawer closes.
    if (here === route || (route === SETTINGS.route && here.startsWith(route + "/"))) return closeDrawer();
    const fromStart = routeOf(here) === START;
    if (drawerEntry.current) {
      drawerEntry.current = false;
      setDrawer(false);
      if (fromStart) return navigate(route, true); // the drawer's entry becomes the page
      pending.current = route; // drop the drawer's entry, then replace this page
      return window.history.back();
    }
    navigate(route, !fromStart);
  };

  const openDrawer = () => {
    window.history.pushState({ ghostpenDrawer: true }, "");
    drawerEntry.current = true;
    setDrawer(true);
  };

  const closeDrawer = () => {
    if (drawerEntry.current) {
      drawerEntry.current = false;
      window.history.back(); // popstate closes it
    } else setDrawer(false);
  };

  useEffect(() => {
    const onPop = () => {
      drawerEntry.current = false;
      setDrawer(false);
      const route = pending.current;
      pending.current = null;
      if (route) navigate(route, true);
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  useEffect(() => {
    // A page the backend asked for before this one listened (startup).
    uiState()
      .then((s) => {
        setUi(s);
        if (s.route !== current) go(s.route);
      })
      .catch((e) => console.warn("ui_state:", e));
    const off = listen<string>("ghostpen://navigate", (e) => go(e.payload));
    const mq = window.matchMedia(NARROW);
    const onMq = () => setNarrow(mq.matches);
    mq.addEventListener("change", onMq);
    return () => {
      off.then((f) => f());
      mq.removeEventListener("change", onMq);
    };
  }, []);

  useEffect(() => {
    setVisited((v) => (v.includes(current) ? v : [...v, current]));
  }, [current]);

  const pick = (s: Section) => {
    if (ui && s.floats?.(ui) && s.open) {
      s.open();
      closeDrawer();
      return;
    }
    go(s.route);
  };

  const item = (s: Section) => (
    <button
      key={s.route}
      className={"shell-item" + (s.route === current ? " active" : "")}
      onClick={() => pick(s)}
      title={collapsed && !narrow ? s.label : undefined}
    >
      <Icon name={s.icon} />
      <span className="shell-label">{s.label}</span>
    </button>
  );

  const showSidebar = narrow ? drawer : true;
  const cls = ["shell", narrow ? "narrow" : "", collapsed && !narrow ? "collapsed" : ""].join(" ");

  return (
    <div className={cls}>
      {showSidebar && (
        <nav className="shell-nav" aria-label="GhostPen">
          <div className="shell-brand">
            <button className="shell-toggle" onClick={() => (narrow ? closeDrawer() : setCollapsed((c) => !c))} title="Toggle the sidebar">
              <Icon name="sidebar" />
            </button>
            <span className="shell-label">GhostPen</span>
          </div>
          <div className="shell-items">{SECTIONS.map(item)}</div>
          <div className="shell-foot">
            {item(SETTINGS)}
            {current === SETTINGS.route && (
              <div className="shell-sub">
                {SETTINGS_SECTIONS.map((x) => (
                  <button
                    key={x.id}
                    className={"shell-item" + (settingsSection(path) === x.id ? " active" : "")}
                    onClick={() => go("/settings/" + x.id)}
                  >
                    {x.label}
                  </button>
                ))}
              </div>
            )}
          </div>
        </nav>
      )}
      {narrow && drawer && <div className="shell-scrim" onClick={closeDrawer} />}
      <main className="shell-main">
        {narrow && (
          // Phones and narrow windows: a top app bar with the page's title (the
          // page's own heading is hidden there) and the drawer's button.
          <header className="shell-bar">
            {sub ? (
              <button className="shell-toggle" onClick={() => window.history.back()} title="Back" aria-label="Back">
                <Icon name="back" />
              </button>
            ) : (
              <button className="shell-toggle" onClick={openDrawer} title="Pages" aria-label="Open navigation">
                <Icon name="menu" />
              </button>
            )}
            <h1 className="shell-title">{sub || titleOf(current, path)}</h1>
          </header>
        )}
        <Suspense fallback={null}>
          {ALL.filter((s) => visited.includes(s.route)).map((s) => (
            <section key={s.route} className={"shell-page shell-page-" + s.route.slice(1)} hidden={s.route !== current}>
              {s.page()}
            </section>
          ))}
        </Suspense>
      </main>
    </div>
  );
}
