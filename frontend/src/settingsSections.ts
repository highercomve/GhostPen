// Settings' sections: the page's own nav (a window per tool) or, in the
// single app window, items under Settings in the app's sidebar (Shell.tsx).
export type SettingsSection = "ai" | "models" | "voices" | "actions" | "speech" | "service" | "about";

export const SECTIONS: { id: SettingsSection; label: string; hint: string; description: string }[] = [
  { id: "ai", label: "AI profile", hint: "Choose your provider", description: "Choose the model GhostPen uses for writing, proofreading, and optional translation." },
  { id: "models", label: "Built-in models", hint: "Download and tune", description: "Download models that run on this computer and adjust how they use memory." },
  { id: "voices", label: "Voices", hint: "Read text aloud", description: "The built-in Kokoro voice: download the model and voice packs it reads with." },
  { id: "actions", label: "Actions", hint: "Shortcuts and results", description: "Choose how actions start, where results go, and add your own instructions." },
  { id: "speech", label: "Speech", hint: "Captions and dictation", description: "Choose a speech model and set up captions and dictation." },
  { id: "service", label: "Connections", hint: "Share your models", description: "Choose whether other apps can use your models." },
  { id: "about", label: "About", hint: "Version, system, updates", description: "What's running on this device, how copy and paste work here, and updates." },
];
