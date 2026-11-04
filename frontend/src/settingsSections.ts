// Settings' sections: the page's own nav (a window per tool) or, in the
// single app window, items under Settings in the app's sidebar (Shell.tsx).
export type SettingsSection =
  | "ai" | "models" | "service"
  | "speech" | "captions" | "meetings" | "dictation" | "voices"
  | "actions" | "general" | "about";

/** The group a section sits under in Settings' own nav. */
export type SettingsGroup = "AI" | "Speech" | "App";

export const SECTIONS: { id: SettingsSection; group: SettingsGroup; label: string; hint: string; description: string }[] = [
  { id: "ai", group: "AI", label: "AI profile", hint: "Choose your provider", description: "Choose the model GhostPen uses for writing, proofreading, and optional translation." },
  { id: "models", group: "AI", label: "Built-in models", hint: "Download and tune", description: "Download models that run on this computer and adjust how they use memory." },
  { id: "service", group: "AI", label: "Connections", hint: "Share your models", description: "Choose whether other apps can use your models." },
  { id: "speech", group: "Speech", label: "Speech models", hint: "What hears you", description: "The speech model that captions, meetings and dictation share." },
  { id: "captions", group: "Speech", label: "Captions", hint: "Subtitles for what you hear", description: "Subtitle what plays on this computer, with optional translation." },
  { id: "meetings", group: "Speech", label: "Meetings", hint: "Record and transcribe", description: "Record captions as a meeting, then transcribe, label and proofread it." },
  { id: "dictation", group: "Speech", label: "Dictation", hint: "Speak to type", description: "Speak and have the text typed or copied for you." },
  { id: "voices", group: "Speech", label: "Voices", hint: "Read text aloud", description: "The built-in Kokoro voice: download the model and voice packs it reads with." },
  { id: "actions", group: "App", label: "Actions", hint: "Shortcuts and results", description: "Choose how actions start, where results go, and add your own instructions." },
  { id: "general", group: "App", label: "General", hint: "Window layout", description: "How GhostPen's windows are arranged." },
  { id: "about", group: "App", label: "About", hint: "Version, system, updates", description: "What's running on this device, how copy and paste work here, and updates." },
];
