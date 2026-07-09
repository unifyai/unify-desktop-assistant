import { Page, Browser, BrowserContext, PageScreenshotOptions } from "playwright";
import { ClickWebAction, ScrollWebAction, SwitchTabWebAction, TypeWebAction, WebAction } from '@/web/types';
import { PageStabilityAnalyzer } from "./stability";
import { parseTypeContent } from "./util";
import { ActionVisualizer, ActionVisualizerOptions } from "./visualizer";
import logger from "@/logger";
import { formatLastBrowserLifecycleHint } from "./browserLifecycleDiagnostics";
import { TabManager, TabState } from "./tabs";
import { DOMTransformer } from "./transformer";
import { Image } from '@/memory/image';
import EventEmitter from "eventemitter3";
import * as fs from 'fs';
import * as path from 'path';
import * as os from 'os';
//import { StateComponent } from "@/facets";


// Anthropic's recommended maximum screenshot resolutions for computer-use models.
// Screenshots are scaled down to the matching target when the viewport is larger,
// preserving aspect ratio. No scaling if the viewport already fits or has no
// matching aspect ratio (within 2% tolerance).
// Reference: anthropic-quickstarts/computer-use-demo/tools/computer.py
const MAX_SCALING_TARGETS = [
    { width: 1024, height: 768 },   // XGA, 4:3
    { width: 1280, height: 800 },   // WXGA, 16:10
    { width: 1366, height: 768 },   // FWXGA, ~16:9
];

export interface WebHarnessOptions {
    //fallbackViewportDimensions?: { width: number, height: number}
    // Some LLM operate best on certain screen dims
    virtualScreenDimensions?: { width: number, height: number }
    visuals?: ActionVisualizerOptions
    sessionId?: string
    sessionLabel?: string
}

export interface WebHarnessEvents {
    'activePageChanged': (page: Page) => Promise<void>;
}

export class WebHarness { // implements StateComponent
    /**
     * Executes web actions on a page
     * Not responsible for browser lifecycle
     */
    public readonly context: BrowserContext;
    private options: WebHarnessOptions;
    private stability: PageStabilityAnalyzer;
    public readonly visualizer: ActionVisualizer;
    private transformer: DOMTransformer;
    private tabs: TabManager;

    public readonly events: EventEmitter<WebHarnessEvents> = new EventEmitter();

    constructor(context: BrowserContext, options: WebHarnessOptions = {}) {
        //this.page = page;
        this.context = context;
        this.options = options;
        this.stability = new PageStabilityAnalyzer({ disableVisualStability: true });
        this.visualizer = new ActionVisualizer(this.context, this.options.visuals ?? {});
        this.transformer = new DOMTransformer();
        this.tabs = new TabManager(context, {
            sessionId: options.sessionId,
            sessionLabel: options.sessionLabel,
        });

        // this.context.on('page', (page: Page) => {
        //     this.setActivePage(page);
        //     //logger.info('ayo we got a new page');
        // });
        this.tabs.events.on('tabChanged', async (page: Page) => {
            await this.setActivePage(page);
            // need to wait for page to load before evaluating a script
            //page.on('load', () => { this.transformer.setActivePage(page); });

            //console.log('tabs:', await this.tabs.getState())

        }, this);
    }

    async setActivePage(page: Page) {
        this.stability.setActivePage(page);
        await this.visualizer.setActivePage(page);
        this.transformer.setActivePage(page);
        this.events.emit('activePageChanged', page);
    }

    async retrieveTabState(): Promise<TabState> {
        return this.tabs.retrieveState();
    }

    // setActivePage(page: Page) {
    //     this.page = page;
    //     this.stability.setActivePage(this.page);
    //     this.visualizer.setActivePage(this.page);
    // }

    async start() {
        if (this.context.pages().length > 0) {
            // If context already contains a page, set it as active
            this.tabs.registerExistingPages();
            this.tabs.setActivePage(this.context.pages()[0], "harness_start_existing_page");
        } else {
            await this.context.newPage();
            // Other logic for page tracking is automatically handled by TabManager
        }
        await this.visualizer.setup();
    }

    get page() {
        return this.tabs.getActivePage();
    }

    async screenshot(options: PageScreenshotOptions = {}): Promise<Image> {
        let dpr!: number;
        let buffer!: Buffer<ArrayBufferLike>;
        const retries = 3;

        for (let attempt = 0; attempt <= retries; attempt++) {
            try {
                dpr = await this.page.evaluate(() => window.devicePixelRatio)
                buffer = await this.page.screenshot({ type: 'png', ...options }, );
                break;
            } catch (err) {
                const error = err as Error;
                if (error.message.includes('Target page, context or browser has been closed')) {
                    const hint = formatLastBrowserLifecycleHint();
                    throw new Error(
                        hint
                            ? `Attempted to take screenshot but page, context or browser is closed. ${hint}`
                            : "Attempted to take screenshot but page, context or browser is closed",
                    );
                }
                if (attempt >= retries) {
                    throw new Error(`Unable to capture screenshot after retries, error: ${error.message}`);
                }
            }
        }

        const base64data = buffer.toString('base64');

        const image = Image.fromBase64(base64data);

        // Rescale by 1/DPR so coordinates match CSS pixels
        const { width, height } = await image.getDimensions();
        const rescaledImage = await image.resize(width / dpr, height / dpr);
        const vp = this.page.viewportSize();
        logger.debug({
            dpr,
            rawWidth: width, rawHeight: height,
            rescaledWidth: Math.round(width / dpr), rescaledHeight: Math.round(height / dpr),
            viewportWidth: vp?.width, viewportHeight: vp?.height,
            virtualScreen: this.options.virtualScreenDimensions,
            pageUrl: this.page.url(),
        }, "Screenshot captured");
        return rescaledImage;

        // return {
        //     image: `data:image/png;base64,${base64data}`,//buffer.toString('base64'),
        //     dimensions: {
        //         width: viewportSize.width,
        //         height: viewportSize.height
        //     }
        // };
    }

    // async goto(url: string) {
    //     // No need to redraw here anymore, the 'load' event listener handles it
    //     await this.page.goto(url);
    // }

    async _type(content: string) {
        /** Util for typing + keypresses */
        const chunks = parseTypeContent(content);

        // Total typing period to make typing more natural, in ms
        const totalTextDelay = 500;

        let totalTextLength = 0
        for (const chunk of chunks) {
            if (chunk != '<enter>' && chunk != '<tab>') {
                totalTextLength += chunk.length;
            }
        }

        for (const chunk of chunks) {
            if (chunk == '<enter>') {
                await this.page.keyboard.press('Enter');
            } else if (chunk == '<tab>') {
                await this.page.keyboard.press('Tab')
            } else {
                const chunkProportion = chunk.length / totalTextLength;
                const chunkDelay = totalTextDelay * chunkProportion;
                const chunkCharDelay = chunkDelay / chunk.length;
                await this.page.keyboard.type(chunk, {delay: chunkCharDelay});
            }
        }
    }

    /**
     * Determine the scaling target for the given viewport dimensions.
     * Implements Anthropic's aspect-ratio-aware scaling: matches the viewport's
     * aspect ratio to the closest MAX_SCALING_TARGETS entry (within 2% tolerance),
     * and only scales down (never up). Returns null if no scaling is needed.
     */
    getScalingTarget(vpWidth: number, vpHeight: number): { width: number; height: number } | null {
        if (this.options.virtualScreenDimensions) {
            return this.options.virtualScreenDimensions;
        }
        const ratio = vpWidth / vpHeight;
        for (const target of MAX_SCALING_TARGETS) {
            if (Math.abs(target.width / target.height - ratio) < 0.02) {
                if (target.width < vpWidth) {
                    return target;
                }
            }
        }
        return null;
    }

    /**
     * Scale coordinates from screenshot/virtual space UP to actual viewport space.
     * Uses aspect-ratio-aware scaling at runtime based on the current viewport.
     */
    async transformCoordinates({ x, y }: { x: number, y: number }): Promise<{ x: number, y: number }> {
        let vp = this.page.viewportSize();
        if (!vp) {
            vp = await this.page.evaluate(() => ({
                width: window.innerWidth,
                height: window.innerHeight
            }));
        }
        if (!vp) throw new Error("Could not get viewport dimensions to transform coordinates");
        const target = this.getScalingTarget(vp.width, vp.height);
        if (!target) {
            logger.debug({ rawX: x, rawY: y, transform: 'none' }, "No scaling target — coordinates unchanged");
            return { x, y };
        }
        const transformed = {
            x: Math.round(x * (vp.width / target.width)),
            y: Math.round(y * (vp.height / target.height)),
        };
        logger.debug({
            rawX: x, rawY: y,
            transformedX: transformed.x, transformedY: transformed.y,
            viewport: vp, scalingTarget: target,
        }, "Coordinate transform applied");
        return transformed;
    }

    async click({ x, y }: { x: number, y: number }, options?: { transform: boolean }) {
        const rawX = x, rawY = y;
        if (options?.transform ?? true) ({ x, y } = await this.transformCoordinates({ x, y }));
        logger.debug({ rawX, rawY, finalX: Math.round(x), finalY: Math.round(y) }, "click");
        await this._click(x, y);
        await this.waitForStability();
    }

    private async _click(x: number, y: number, options?: {
        button?: "left" | "right" | "middle";
        clickCount?: number;
        delay?: number;
    }) {
        await Promise.all([
            this.visualizer.moveVirtualCursor(x, y),
            this.page.mouse.move(x, y, { steps: 20 })
        ])
        // await this.visualizer.moveVirtualCursor(x, y);
        // await this.page.mouse.move(x, y, { steps: 20 });
        await this.visualizer.hideAll(); // hide / show pointer because no-pointer is not always consistent and visualizer can block click
        await this.page.mouse.click(x, y, {
            button: options?.button ?? "left",
            clickCount: options?.clickCount,
            delay: options?.delay,
        });
        await this.visualizer.showAll();
    }

    async rightClick({ x, y }: { x: number, y: number }, options?: { transform: boolean }) {
        const rawX = x, rawY = y;
        if (options?.transform ?? true) ({ x, y } = await this.transformCoordinates({ x, y }));
        logger.debug({ rawX, rawY, finalX: Math.round(x), finalY: Math.round(y) }, "rightClick");
        await this._click(x, y, { button: "right" });
        await this.waitForStability();
    }

    async doubleClick({ x, y }: { x: number, y: number }, options?: { transform: boolean }) {
        const rawX = x, rawY = y;
        if (options?.transform ?? true) ({ x, y } = await this.transformCoordinates({ x, y }));
        logger.debug({ rawX, rawY, finalX: Math.round(x), finalY: Math.round(y) }, "doubleClick");
        await this.visualizer.moveVirtualCursor(x, y);
        await this.visualizer.hideAll();
        await this.page.mouse.dblclick(x, y);
        await this.visualizer.showAll();
        await this.waitForStability();
    }

    async drag({ x1, y1, x2, y2 }: { x1: number, y1: number, x2: number, y2: number }, options?: { transform: boolean }) {
        const rawFrom = { x: x1, y: y1 }, rawTo = { x: x2, y: y2 };
        if (options?.transform ?? true) ({ x: x1, y: y1 } = await this.transformCoordinates({ x: x1, y: y1 }));
        if (options?.transform ?? true) ({ x: x2, y: y2 } = await this.transformCoordinates({ x: x2, y: y2 }));

        logger.debug({
            rawFrom, rawTo,
            finalFrom: { x: Math.round(x1), y: Math.round(y1) },
            finalTo: { x: Math.round(x2), y: Math.round(y2) },
        }, "drag start");

        const t0 = Date.now();
        await this.page.mouse.move(x1, y1, { steps: 1 });
        await this.page.mouse.down();
        await this.visualizer.moveVirtualCursor(x1, y1);
        logger.debug({ x: Math.round(x1), y: Math.round(y1), phase: 'mousedown', ms: Date.now() - t0 }, "drag mousedown");

        await this.page.waitForTimeout(500);

        await Promise.all([
            this.page.mouse.move(x2, y2, { steps: 20 }),
            this.visualizer.moveVirtualCursor(x2, y2)
        ]);
        logger.debug({ x: Math.round(x2), y: Math.round(y2), phase: 'moved', ms: Date.now() - t0 }, "drag interpolation done");

        await this.page.mouse.up();
        logger.debug({ phase: 'mouseup', ms: Date.now() - t0 }, "drag mouseup");

        await this.waitForStability();
    }

    /**
     * Move the cursor to (x, y) along a randomized cubic-bezier path with
     * ease-in-out timing, emitting many small mouse.move events (like a human
     * hand) instead of a single teleport. Intended for anti-bot pacing on
     * scripted trajectories — `click`/`scroll` still snap for speed.
     *
     * The start point is the last known cursor position (falling back to the
     * viewport centre). Two control points are offset from the straight line
     * by a random fraction of the travel distance, so the arc bows gently and
     * never repeats. Step count and per-step delay scale with distance.
     */
    async moveHumanlike(
        { x, y }: { x: number, y: number },
        options?: { transform?: boolean, steps?: number }
    ) {
        const rawX = x, rawY = y;
        if (options?.transform ?? true) ({ x, y } = await this.transformCoordinates({ x, y }));

        const vp = this.page.viewportSize() ?? { width: 1024, height: 768 };
        const start = this.getCursorPosition() ?? {
            x: Math.round(vp.width / 2),
            y: Math.round(vp.height / 2),
        };

        const dist = Math.hypot(x - start.x, y - start.y);
        const steps = Math.max(
            12,
            Math.min(60, options?.steps ?? Math.round(dist / 8) + 12)
        );

        const jitter = () => (Math.random() - 0.5) * 2; // [-1, 1]
        const bow = Math.min(120, dist * 0.2);
        const c1 = {
            x: start.x + (x - start.x) * 0.33 + jitter() * bow,
            y: start.y + (y - start.y) * 0.33 + jitter() * bow,
        };
        const c2 = {
            x: start.x + (x - start.x) * 0.66 + jitter() * bow,
            y: start.y + (y - start.y) * 0.66 + jitter() * bow,
        };

        for (let i = 1; i <= steps; i++) {
            const t = i / steps;
            // ease-in-out cubic: accelerate away, decelerate into the target
            const e = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
            const m = 1 - e;
            const px = m*m*m*start.x + 3*m*m*e*c1.x + 3*m*e*e*c2.x + e*e*e*x;
            const py = m*m*m*start.y + 3*m*m*e*c1.y + 3*m*e*e*c2.y + e*e*e*y;
            await this.page.mouse.move(px, py);
            await this.page.waitForTimeout(4 + Math.random() * 12);
        }

        // Land exactly on target and keep the visual cursor in sync.
        await Promise.all([
            this.page.mouse.move(x, y),
            this.visualizer.moveVirtualCursor(x, y),
        ]);
        logger.debug(
            { rawX, rawY, finalX: Math.round(x), finalY: Math.round(y), steps },
            "moveHumanlike"
        );
    }

    async type({ content }: { content: string }) {
        await this._type(content);
        await this.waitForStability();
    }

    async clickAndType({ x, y, content }: { x: number, y: number, content: string }) {
        // TODO: transforms incorrect for moondream grounding with virtual screen dims (claude) - unsure why
        //console.log(`Pre transform: ${x}, ${y}`);
        ({ x, y } = await this.transformCoordinates({ x, y }));
        //console.log(`Post transform: ${x}, ${y}`);
        await this.visualizer.moveVirtualCursor(x, y);
        this._click(x, y);
        await this._type(content);
        await this.waitForStability();
    }

    async scroll({ x, y, deltaX, deltaY }: { x: number, y: number, deltaX: number, deltaY: number }, options?: { transform: boolean }) {
        const rawX = x, rawY = y;
        if (options?.transform ?? true) ({ x, y } = await this.transformCoordinates({ x, y }));
        logger.debug({ rawX, rawY, finalX: Math.round(x), finalY: Math.round(y), deltaX, deltaY }, "scroll");
        await this.visualizer.moveVirtualCursor(x, y);
        await this.page.mouse.move(x, y);
        await this.page.mouse.wheel(deltaX, deltaY);
        await this.waitForStability();
    }

    async switchTab({ index }: { index: number }) {
        await this.tabs.switchTab(index);
        await this.waitForStability();
    }

    async closeTab({ index }: { index: number }) {
        await this.tabs.closeTab(index);
        await this.waitForStability();
    }

    async newTab() {
        console.log("switching to new tab...");
        await this.context.newPage();
        await this.waitForStability(); // Wait for the new blank page to be ready
    }

    async navigate(url: string) {
        // Only wait for DOM content on goto since we handle waiting for network idle etc ourselves
        await this.page.goto(url, { waitUntil: 'domcontentloaded' });
        await this.waitForStability();
    }

    async selectAll() {
        await this.page.keyboard.down('ControlOrMeta');
        await this.page.keyboard.press('KeyA');
        await this.page.keyboard.up('ControlOrMeta');
    }

    async enter() {
        await this.page.keyboard.press('Enter')
    }

    async backspace() {
        await this.page.keyboard.press('Backspace')
    }

    async tab() {
        await this.page.keyboard.press('Tab')
    }

    async keyPress(key: string) {
        await this.page.keyboard.press(key);
    }

    async goBack() {
        // Initiate the back navigation. On SPAs, this may time out while waiting for an
        // event that never fires. We'll catch this specific error and proceed.
        try {
            // We use a shorter, reasonable timeout.
            await this.page.goBack({ waitUntil: 'domcontentloaded', timeout: 5000 });
        } catch (error) {
            if (error instanceof Error && error.message.includes('Timeout')) {
                // This is an expected outcome on SPAs. We can safely ignore the timeout
                // and rely on our visual stability check below.
                logger.trace('page.goBack() timed out, which is expected for a Single-Page Application. Continuing...');
            } else {
                // If it's a different error, we should re-throw it.
                throw error;
            }
        }

        // This will now wait for the page to become visually and network-stable,
        // which is a much more reliable way to handle SPA navigation.
        await this.waitForStability();
    }

    async executeAction(action: WebAction) {
        if (action.variant === 'click') {
            await this.click(action);
        } else if (action.variant === 'type') {
            await this.clickAndType(action);
        } else if (action.variant === 'scroll') {
            await this.scroll(action);
        } else if (action.variant === 'tab') {
            await this.switchTab(action);
        } else {
            throw Error(`Unhandled web action variant: ${(action as any).variant}`);
        }
        //await this.stability.waitForStability();
        //await this.visualizer.redrawLastPosition();
    }

    async waitForStability(timeout?: number): Promise<void> {
        await this.stability.waitForStability(timeout);
    }

    getCursorPosition(): { x: number; y: number } | null {
        return this.visualizer.getCursorPosition();
    }

    private getStatePath(name: string): string {
        const stateDir = path.join(os.homedir(), '.magnitude', 'browser_states');
        // Ensure directory exists
        if (!fs.existsSync(stateDir)) {
            fs.mkdirSync(stateDir, { recursive: true });
        }
        // Sanitize name to be safe for filesystem
        const safeName = name.replace(/[^a-z0-9_-]/gi, '_');
        return path.join(stateDir, `${safeName}.json`);
    }

    async saveState(name: string): Promise<string> {
        const statePath = this.getStatePath(name);
        // This captures cookies, localStorage, and sessionStorage
        await this.context.storageState({ path: statePath });
        logger.info(`Browser state saved to ${statePath}`);
        return statePath;
    }

    // async applyTransformations() {
    //     const start = Date.now();
    //     await this.transformer.applyTransformations();
    //     logger.trace(`DOM transformations took ${Date.now() - start}ms`);
    // }

    // async waitForStability(timeout?: number): Promise<void> {
    //     await this.stability.waitForStability(timeout);
    // }
}
