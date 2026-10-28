// lib/watcher/loginSignal.ts
// Pure and I/O-free — see scripts/watcher-daemon.ts's waitForStoredLogin and
// waitForDiscoveredLogin for the polling loops that feed this.
//
// A single instantaneous "no password field visible + cookies changed + not
// a login URL" reading is not reliable proof of a real login: clicking
// "forgot password" (or any other page a site shows without a password
// input) produces exactly that reading for as long as the student is on it,
// without any authentication having happened. This burned a real login
// attempt on 2026-09-12 — the student saw iBacalao's own "connected"
// confirmation while the account was, verifiably, still signed out.
//
// Fix: require the reading to hold continuously across several consecutive
// polls, not just once. A genuine login lands somewhere and stays there; a
// transient non-login page (forgot-password, an intermediate redirect) is
// something the student clicks through and leaves within a poll or two.
export const STABLE_LOGIN_POLLS_REQUIRED = 6;

export function loginSignalHoldsSteady(readings: boolean[], required = STABLE_LOGIN_POLLS_REQUIRED): boolean {
  if (readings.length < required) return false;
  return readings.slice(-required).every(Boolean);
}

/** Consecutive polls that still show a login wall — pause LMS only then. */
export function loginWallHoldsSteady(readings: boolean[], required = STABLE_LOGIN_POLLS_REQUIRED): boolean {
  return loginSignalHoldsSteady(readings, required);
}
