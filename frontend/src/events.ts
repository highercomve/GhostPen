// The event API the components were written against (Tauri's shape:
// `listen` resolves to an unlisten function and the callback gets
// `{ payload }`), on top of Oriel's `window.oriel.listen`.

export type UnlistenFn = () => void;

export interface Event<T> {
  payload: T;
}

export function listen<T = unknown>(event: string, handler: (event: Event<T>) => void): Promise<UnlistenFn> {
  return Promise.resolve(window.oriel.listen(event, (payload) => handler({ payload: payload as T })));
}
