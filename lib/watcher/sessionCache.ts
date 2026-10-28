// lib/watcher/sessionCache.ts
// The daemon keeps one browser session per profile across polls (closing it
// would drop session-only school cookies). A cached handle whose Chromium died
// — Mac sleep, crash, the student closing the window — must be replaced, not
// reused: reusing it fails every poll with "Target page, context or browser
// has been closed" until the app restarts the daemon.

export type CachedSession = { isClosed(): boolean; close(): Promise<void> };

export function createSessionCache<S extends CachedSession>(open: (platform: string, profileKey: string) => Promise<S>) {
  const sessions = new Map<string, S>();

  async function close(profileKey: string): Promise<void> {
    const existing = sessions.get(profileKey);
    if (!existing) return;
    sessions.delete(profileKey);
    await existing.close().catch(() => undefined);
  }

  return {
    async get(platform: string, profileKey: string): Promise<S> {
      const existing = sessions.get(profileKey);
      if (existing && !existing.isClosed()) return existing;
      if (existing) {
        console.warn(`[watcher] browser for ${profileKey} was closed; reopening the saved profile`);
        await close(profileKey);
      }
      const session = await open(platform, profileKey);
      sessions.set(profileKey, session);
      return session;
    },
    /** Hand an already-open session (the student's login window) to the polling loop. */
    adopt(profileKey: string, session: S): void {
      sessions.set(profileKey, session);
    },
    close,
    async closeAll(): Promise<void> {
      const all = Array.from(sessions.values());
      sessions.clear();
      await Promise.all(all.map((session) => session.close().catch(() => undefined)));
    },
  };
}
