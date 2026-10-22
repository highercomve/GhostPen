import { useCallback, useEffect, useRef, useState } from "react";
import { listen } from "./events";
import { meetingsRecordingStatus, meetingsStartRecording, meetingsStopRecording, type MeetingRecordingStatus } from "./api";

function elapsed(seconds: number) {
  const n = Math.max(0, Math.floor(seconds));
  return `${Math.floor(n / 3600) ? `${Math.floor(n / 3600)}:` : ""}${String(Math.floor(n / 60) % 60).padStart(2, "0")}:${String(n % 60).padStart(2, "0")}`;
}

/** The recorder stays independent of the selected meeting and survives navigation
 * through the library. Closing the window leaves capture running in the app. */
export default function MeetingRecorder({ onRecorded }: { onRecorded: (id: string) => void }) {
  const [status, setStatus] = useState<MeetingRecordingStatus | null>(null);
  const [action, setAction] = useState<"starting" | "stopping" | null>(null);
  const [error, setError] = useState("");
  const mounted = useRef(false);
  const request = useRef(0);
  const current = useRef<MeetingRecordingStatus | null>(null);

  const refresh = useCallback(async () => {
    const ticket = ++request.current;
    try {
      const next = await meetingsRecordingStatus();
      if (mounted.current && ticket === request.current) {
        current.current = next;
        setStatus(next);
      }
    } catch (e) {
      if (mounted.current && ticket === request.current) setError(String(e));
    }
  }, []);

  useEffect(() => {
    mounted.current = true;
    void refresh();
    const timer = window.setInterval(refresh, 1000);
    const unlisten = listen<string>("ghostpen://caption-error", (e) => {
      if (current.current?.recording || current.current?.starting) setError(e.payload);
    });
    return () => {
      mounted.current = false;
      request.current++;
      window.clearInterval(timer);
      unlisten.then((f) => f());
    };
  }, [refresh]);

  const id = status?.recording?.id;
  useEffect(() => { if (id) onRecorded(id); }, [id, onRecorded]);

  const start = async () => {
    setError("");
    setAction("starting");
    try {
      const recording = await meetingsStartRecording();
      if (mounted.current && recording) onRecorded(recording.id);
    } catch (e) {
      if (mounted.current) setError(String(e));
    } finally {
      if (mounted.current) {
        setAction((a) => a === "starting" ? null : a);
        await refresh();
      }
    }
  };

  const stop = async () => {
    setAction("stopping");
    try {
      await meetingsStopRecording();
    } catch (e) {
      if (mounted.current) setError(String(e));
    } finally {
      if (mounted.current) {
        setAction(null);
        await refresh();
      }
    }
  };

  const recording = status?.recording;
  const starting = action === "starting" || status?.starting;
  const stopping = action === "stopping" || status?.stopping;
  const blocked = !status || status.captions_running;
  return (
    <section className={`mt-recorder ${recording ? "is-recording" : ""}`} aria-label="Meeting recorder">
      <header className="mt-workspace-head">
        <h1>Meetings</h1>
        {(recording || starting || stopping || !status || status.captions_running) && <div className="mt-record-status" role="status">
          {recording ? <><span className="mt-record-dot" aria-hidden="true" /><strong>Recording <span className="mt-rec-clock">{elapsed(recording.seconds)}</span></strong></>
            : stopping ? "Finishing audio files…"
            : starting ? "Opening audio sources…"
            : !status ? "Checking recorder…"
            : "Live captions are using audio capture. Stop them before starting a recording here."}
        </div>}
        {recording || starting || stopping ? (
          <button className="mt-record-button stop" disabled={stopping} onClick={stop}>
            <span className="mt-record-stop" aria-hidden="true" />
            {stopping ? "Saving recording…" : starting ? "Cancel start" : "Stop and save"}
          </button>
        ) : (
          <button className="mt-record-button" disabled={blocked} onClick={start}>
            <span className="mt-record-dot" aria-hidden="true" /> Record meeting
          </button>
        )}
      </header>
      {error && <div className="mt-record-error" role="alert">{error}<button aria-label="Dismiss recording error" onClick={() => setError("")}>×</button></div>}
    </section>
  );
}
