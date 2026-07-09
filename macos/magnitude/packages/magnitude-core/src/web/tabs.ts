// Keeps track of current tab, enables describing open tabs, and switching between open tabs

import logger from "@/logger";
import EventEmitter from "eventemitter3";
import { BrowserContext, Page } from "playwright";
import { logActivePageChanged, markPageCloseProgrammatic } from "./browserLifecycleDiagnostics";

export interface TabEvents {
    'tabChanged': (page: Page) => void
}

export interface TabManagerOptions {
    sessionId?: string;
    sessionLabel?: string;
}

export interface TabState {
    activeTab: number,
    tabs: {
        title: string,
        url: string,
        // causes issues with circular references, and we don't need it
        //page: Page
    }[]
}

export class TabManager {
    /**
     * Page / tab manager
     */
    //private state!: TabState;
    private context: BrowserContext;
    private activePage!: Page; // the page the agent currently sees and acts on
    public readonly events: EventEmitter<TabEvents>;
    private readonly sessionId?: string;
    private readonly sessionLabel?: string;
    private readonly registeredPages = new WeakSet<Page>();

    constructor(context: BrowserContext, options: TabManagerOptions = {}) {
        this.context = context;
        this.sessionId = options.sessionId;
        this.sessionLabel = options.sessionLabel;
        this.events = new EventEmitter();

        // By default when a new page is created
        // (for any reason - just started, agent clicked something, user did new page), set it to active
        this.context.on('page', this.onPageCreated.bind(this));
    }

    private async onPageCreated(page: Page) {
        this.registerPage(page);
        // set active page immediately since agent and helpers expect it to exist
        this.setActivePage(page, "new_page_created");
    }

    registerExistingPages() {
        for (const page of this.context.pages()) {
            this.registerPage(page);
        }
    }

    private registerPage(page: Page) {
        if (this.registeredPages.has(page)) return;
        this.registeredPages.add(page);
        page.on("close", () => this.onPageClosed(page));
    }

    private onPageClosed(closedPage: Page) {
        if (closedPage !== this.activePage) return;

        const remaining = this.context.pages().filter((page) => page !== closedPage);
        if (remaining.length === 0) return;

        const nextPage = remaining[remaining.length - 1];
        logger.warn(
            {
                closedUrl: safePageUrl(closedPage),
                nextUrl: safePageUrl(nextPage),
                remainingTabCount: remaining.length,
            },
            "Active Playwright page closed; switching automation to a remaining tab",
        );
        void this.switchTab(this.context.pages().indexOf(nextPage));
    }

    public setActivePage(page: Page, reason = "set_active_page") {
        this.activePage = page;
        logActivePageChanged(this.context, page, reason, {
            sessionId: this.sessionId,
            sessionLabel: this.sessionLabel,
        });
        this.events.emit('tabChanged', page);
    }

    async switchTab(index: number) {
        const pages = this.context.pages();
        if (index < 0 || index >= pages.length) {
            throw new Error(`Invalid tab index: ${index}`);
        }
        const page = pages[index];
        await page.bringToFront();
        this.setActivePage(page, "switch_tab");
    }

    getActivePage() {
        return this.activePage;
    }

    getPages(): Page[] {
        return this.context.pages();
    }
    
    async closeTab(index: number) {
        const pagesBefore = this.context.pages();
        if (index < 0 || index >= pagesBefore.length) {
            throw new Error(`Invalid tab index: ${index}`);
        }

        const closingPage = pagesBefore[index];
        const isClosingActive = closingPage === this.activePage;

        markPageCloseProgrammatic(closingPage);
        await closingPage.close();

        // Determine next active page
        let pagesAfter = this.context.pages();
        if (pagesAfter.length === 0) {
            // Ensure there is always at least one page available
            const newPage = await this.context.newPage();
            this.setActivePage(newPage, "close_last_tab_replaced");
            return;
        }

        // If the closed tab was active, pick the nearest remaining tab
        if (isClosingActive) {
            const newIndex = Math.min(index, pagesAfter.length - 1);
            const nextPage = pagesAfter[newIndex];
            await nextPage.bringToFront();
            this.setActivePage(nextPage, "close_tab_recovery");
        } else {
            // If we closed a background tab, keep the current active page
            // Ensure activePage still references an existing page
            if (!pagesAfter.includes(this.activePage)) {
                const fallback = pagesAfter[Math.min(index, pagesAfter.length - 1)];
                await fallback.bringToFront();
                this.setActivePage(fallback, "close_background_tab_recovery");
            }
        }
    }

    async retrieveState(): Promise<TabState> {
        //return this.state;
        let activeIndex = -1;
        let tabs = [];
        for (const [i, page] of this.context.pages().entries()) {
            if (page == this.activePage) {
                activeIndex = i;
            }
            // may need retries
            let title: string;
            try {
                title = await page.title();
            } catch {
                logger.warn('Could not load page title while retrieving tab state');
                title = '(could not load title)';
            }
            
            const url = page.url();
            tabs.push({ title, url });//, page });
        }
        return {
            activeTab: activeIndex,
            tabs: tabs
        };
    }
}

function safePageUrl(page: Page): string {
    try {
        return page.url();
    } catch {
        return "(url unavailable)";
    }
}