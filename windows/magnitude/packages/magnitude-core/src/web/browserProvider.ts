import { Browser, BrowserContext, BrowserContextOptions, chromium, LaunchOptions, CDPSession } from "playwright";
import objectHash from 'object-hash';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import logger from "@/logger";
import { Logger } from 'pino';
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
import {
    applyStealthToContext,
    stealthContextOptions,
    stealthEnabled,
    STEALTH_IGNORE_DEFAULT_ARGS,
    STEALTH_LAUNCH_ARGS,
} from "@/web/stealth";

const DEFAULT_BROWSER_OPTIONS: LaunchOptions = {
    headless: false,
    args: ["--disable-gpu", "--disable-blink-features=AutomationControlled"],
};

// `stealth` is opt-in anti-automation hardening (see web/stealth.ts). It can be
// set per-session here or globally via the MAGNITUDE_STEALTH env var.
export type BrowserOptions = { instance: Browser; contextOptions?: BrowserContextOptions; storageStateName?: string; stealth?: boolean; }
    | { cdp: string; contextOptions?: BrowserContextOptions; storageStateName?: string; stealth?: boolean; }
    | { launchOptions?: LaunchOptions; contextOptions?: BrowserContextOptions; storageStateName?: string; stealth?: boolean; }
    | { context: BrowserContext };

interface ActiveBrowser {
    // either a browser still being launched or already resolved and ready
    browserPromise: Promise<Browser>;
    activeContextsCount: number;
}

const DEFAULT_BROWSER_CONTEXT_OPTIONS: BrowserContextOptions = {
    viewport: { width: 1024, height: 768 },
}

export class BrowserProvider {
    private activeBrowsers: Record<string, ActiveBrowser> = {};
    private logger: Logger;
    public events = new EventEmitter();

    private constructor() {
        this.logger = logger.child({ name: 'browser_provider' });
    }

    public static getInstance(): BrowserProvider {
        if (!(globalThis as any).__magnitude__) {
            (globalThis as any).__magnitude__ = {};
        }

        if (!(globalThis as any).__magnitude__.browserProvider) {
            (globalThis as any).__magnitude__.browserProvider = new BrowserProvider();
        }

        return (globalThis as any).__magnitude__.browserProvider;
    }

    private getStatePath(name: string): string {
        const stateDir = path.join(os.homedir(), '.magnitude', 'browser_states');
        const safeName = name.replace(/[^a-z0-9_-]/gi, '_');
        return path.join(stateDir, `${safeName}.json`);
    }

    private async _launchOrReuseBrowser(options: LaunchOptions): Promise<ActiveBrowser> {
        // hash options
        const hash = objectHash({
            ...options,
            logger: options.logger ? crypto.randomUUID() : '' // replace unserializable logger - use UUID to force re-instance in case different loggers provided
        });
        
        let activeBrowser: ActiveBrowser;
        if (!(hash in this.activeBrowsers)) {
            this.logger.trace("Launching new browser");
            // Launch new browser, get the PROMISE
            const launchPromise = chromium.launch({ ...DEFAULT_BROWSER_OPTIONS, ...options });

            activeBrowser = {
                browserPromise: launchPromise,
                activeContextsCount: 0
            };
            // add immediately in case others need to await the same one as well
            this.activeBrowsers[hash] = activeBrowser;

            // Wait for browser to fully start
            const browser = await launchPromise;

            browser.on('disconnected', () => {
                delete this.activeBrowsers[hash];
                this.events.emit('browserDisconnected', { browser });
                this.logger.warn(
                    { launchOptionsHash: hash.slice(0, 8) },
                    "[browser-lifecycle] browser_disconnected (BrowserProvider)",
                );
            });

            return activeBrowser;
        } else {
            this.logger.trace("Browser with same launch options exists, reusing");
            return this.activeBrowsers[hash];
        }
    }

    public async _createAndTrackContext(options: BrowserOptions): Promise<BrowserContext> {
        const activeBrowserEntry = await this._launchOrReuseBrowser('launchOptions' in options ? options.launchOptions! : {});
        const browser = await activeBrowserEntry.browserPromise;
        
        const contextOptions = 'contextOptions' in options ? options.contextOptions : undefined;

        const context = await browser.newContext(contextOptions);

        // When viewport is explicitly null the page follows the browser
        // window size dynamically (resizing the window reflows content).
        // Only pin the viewport via CDP when a fixed size is requested.
        const resolvedViewport = contextOptions?.viewport;
        if (resolvedViewport) {
            const deviceScaleFactor = contextOptions?.deviceScaleFactor || 1;
            context.on('page', async (page) => {
                const cdpSession = await page.context().newCDPSession(page);
                await this._applyEmulationSettings(cdpSession, resolvedViewport.width, resolvedViewport.height, deviceScaleFactor);
            });
        }

        activeBrowserEntry.activeContextsCount++;

        context.on('close', async () => {
            activeBrowserEntry.activeContextsCount--;
            this.logger.warn(
                {
                    activeContextsCount: activeBrowserEntry.activeContextsCount,
                    browserConnected: browser.isConnected(),
                },
                "[browser-lifecycle] context_closed (BrowserProvider)",
            );
            if (activeBrowserEntry.activeContextsCount <= 0 && browser.isConnected()) {
                await browser.close();
            }
        });
        return context;
    }

    public async newContext(options?: BrowserOptions): Promise<BrowserContext> {
        if (options && 'context' in options) {
            // Context directly provided, we don't need to manage it
            return options.context;
        }

        // Opt-in anti-automation hardening: per-session flag OR global env var.
        const useStealth = stealthEnabled()
            || (!!options && 'stealth' in options && (options as any).stealth === true);

        const dpr = process.env.DEVICE_PIXEL_RATIO ?
            parseInt(process.env.DEVICE_PIXEL_RATIO) :
            process.platform === 'darwin' ? 2 : 1;
        
        let contextOptions: BrowserContextOptions = {
            ...DEFAULT_BROWSER_CONTEXT_OPTIONS,
            deviceScaleFactor: dpr,
            // Stealth fills realistic defaults (locale/timezone/UA); explicit
            // contextOptions still win.
            ...(useStealth ? stealthContextOptions() : {}),
            ...(options && 'contextOptions' in options && options.contextOptions ? options.contextOptions : {})
        };

        if (contextOptions.viewport === null) {
            delete contextOptions.deviceScaleFactor;
        }

        // INJECT STORAGE STATE IF PROVIDED
        if (options && 'storageStateName' in options && options.storageStateName) {
            const statePath = this.getStatePath(options.storageStateName);
            if (fs.existsSync(statePath)) {
                this.logger.info(`Loading storage state from: ${statePath}`);
                // This is the magic Playwright line that loads cookies/storage BEFORE page load
                contextOptions.storageState = statePath;
            } else {
                this.logger.warn(`Requested storage state '${options.storageStateName}' not found at ${statePath}`);
            }
        }

        options = { ...options, contextOptions };

        if (process.env.MAGNTIUDE_PLAYGROUND) {
            // this.logger.trace("MAGNITUDE_PLAYGROUND environment detected, connecting to browser via CDP");
            // Playground environment - force use CDP on 9222
            //const browser = await chromium.connectOverCDP('http://localhost:9222');
            //return browser.newContext(options?.contextOptions);
            this.logger.trace("MAGNITUDE_PLAYGROUND environment detected, applying playground launch options");
            const playgroundLaunchOptions = {
                args: [
                    '--remote-debugging-port=9222',
                    '--no-sandbox',
                    '--disable-dev-shm-usage',
                    '--disable-gpu'
                ]
            };
            // Overwrite any launch options, instance, or cdp configuration with playground launch options
            // Ignore context options (?)
            options = {
                launchOptions: playgroundLaunchOptions
            };
        }
        
        // Merge stealth launch args + drop the automation switch (managed
        // browsers only — cdp/instance browsers are launched externally).
        if (useStealth && !('cdp' in options) && !('instance' in options)) {
            const lo = ('launchOptions' in options ? options.launchOptions : undefined) ?? {};
            const args = Array.from(new Set([...(lo.args ?? []), ...STEALTH_LAUNCH_ARGS]));
            const ignoreDefaultArgs = Array.from(new Set([
                ...(Array.isArray(lo.ignoreDefaultArgs) ? lo.ignoreDefaultArgs : []),
                ...STEALTH_IGNORE_DEFAULT_ARGS,
            ]));
            options = { ...options, launchOptions: { ...lo, args, ignoreDefaultArgs } };
        }

        let context: BrowserContext;
        if ('cdp' in options) {
            const browser = await chromium.connectOverCDP(options.cdp);
            context = browser.contexts().length > 0
                ? browser.contexts()[0]
                : await browser.newContext(options.contextOptions);
        } else if ('instance' in options) {
            const browser = options.instance;
            context = browser.contexts().length > 0
                ? browser.contexts()[0]
                : await browser.newContext(options.contextOptions);
        } else if ('launchOptions' in options) {
            this.logger.trace('Creating context with custom launch options');
            context = await this._createAndTrackContext(options);
        } else {
            // contextOptions might be passed but no instance | cdp | launchOptions
            this.logger.trace('Creating context for default browser options');
            context = await this._createAndTrackContext(options);
        }

        if (useStealth) {
            await applyStealthToContext(context);
        }
        return context;
    }

    private async _applyEmulationSettings(cdpSession: CDPSession, width: number, height: number, deviceScaleFactor: number) {
        await cdpSession.send('Emulation.setDeviceMetricsOverride', {
            width: width,
            height: height,
            deviceScaleFactor: deviceScaleFactor,
            mobile: false,
            screenWidth: width,
            screenHeight: height,
            positionX: 0,
            positionY: 0,
            screenOrientation: { angle: 0, type: 'portraitPrimary' }
        });
    }
}