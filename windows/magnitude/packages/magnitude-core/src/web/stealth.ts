import type { BrowserContext, BrowserContextOptions } from "playwright";
import logger from "@/logger";

/**
 * Opt-in anti-automation hardening for browser sessions.
 *
 * Off by default. A session turns it on either via the `MAGNITUDE_STEALTH`
 * environment variable or an explicit `stealth: true` in `BrowserOptions`
 * (which the agent-service `/start` endpoint forwards). When on we:
 *
 *  - drop the `--enable-automation` launch switch (which sets
 *    `navigator.webdriver` and the "Chrome is being controlled" infobar) and
 *    add a few conservative launch args;
 *  - fill in realistic context options (locale / timezone / user-agent) *as
 *    defaults* — explicit `contextOptions` always win;
 *  - inject an init script (runs before any page script, in every frame) that
 *    patches the handful of JS tells Playwright leaves behind.
 *
 * The patches are deliberately conservative: we only normalise values a real
 * desktop Chrome would have. Over-spoofing (e.g. faking a GPU that contradicts
 * the actual renderer) *adds* an inconsistency that is itself a fingerprint, so
 * we avoid it.
 */

export function stealthEnabled(): boolean {
    const v = (process.env.MAGNITUDE_STEALTH ?? "").trim().toLowerCase();
    return v === "1" || v === "true" || v === "yes";
}

// Launch args that reduce automation fingerprints. Complements the existing
// `--disable-blink-features=AutomationControlled` default in the provider.
export const STEALTH_LAUNCH_ARGS: string[] = [
    // Keep the provider's baseline args (Playwright *replaces* args, doesn't
    // merge, so we re-list them here for the no-launchOptions path).
    "--disable-gpu",
    "--disable-blink-features=AutomationControlled",
    "--no-default-browser-check",
    "--no-first-run",
    "--disable-infobars",
];

// Chromium's default launch adds `--enable-automation`, which flips
// `navigator.webdriver` on and shows the automation infobar. Dropping it is the
// single highest-value stealth lever.
export const STEALTH_IGNORE_DEFAULT_ARGS: string[] = ["--enable-automation"];

/** Realistic context defaults (explicit contextOptions override these). */
export function stealthContextOptions(): BrowserContextOptions {
    const opts: BrowserContextOptions = {
        locale: process.env.MAGNITUDE_STEALTH_LOCALE || "en-US",
    };
    const tz = process.env.MAGNITUDE_STEALTH_TIMEZONE;
    if (tz) opts.timezoneId = tz;
    const ua = process.env.MAGNITUDE_STEALTH_UA;
    if (ua) opts.userAgent = ua;
    return opts;
}

// Runs in every page/frame before the page's own scripts. Patches the common
// JS-observable tells; each guard is wrapped so one failing patch can't break
// the others or the page.
const STEALTH_INIT_SCRIPT = `
(() => {
  const def = (obj, prop, get) => {
    try { Object.defineProperty(obj, prop, { get, configurable: true }); } catch (e) {}
  };
  // navigator.webdriver: Playwright sets this true; real Chrome reports false.
  def(navigator, 'webdriver', () => false);
  // navigator.languages: ensure a non-empty, plausible list.
  try {
    if (!navigator.languages || navigator.languages.length === 0) {
      def(navigator, 'languages', () => ['en-US', 'en']);
    }
  } catch (e) {}
  // window.chrome: present on real desktop Chrome; provide a minimal shape.
  try { if (!window.chrome) { window.chrome = { runtime: {} }; } } catch (e) {}
  // permissions.query('notifications'): headless returns 'denied' while
  // Notification.permission is 'default' — reconcile the two.
  try {
    const orig = navigator.permissions && navigator.permissions.query;
    if (orig) {
      navigator.permissions.query = (params) =>
        params && params.name === 'notifications'
          ? Promise.resolve({ state: Notification.permission })
          : orig(params);
    }
  } catch (e) {}
})();
`;

/** Add the stealth init script to a managed context. Best-effort. */
export async function applyStealthToContext(context: BrowserContext): Promise<void> {
    try {
        await context.addInitScript(STEALTH_INIT_SCRIPT);
        logger.child({ name: "browser_provider" }).info("[stealth] init script applied");
    } catch (e) {
        logger.child({ name: "browser_provider" }).warn({ err: String(e) }, "[stealth] failed to apply init script");
    }
}
