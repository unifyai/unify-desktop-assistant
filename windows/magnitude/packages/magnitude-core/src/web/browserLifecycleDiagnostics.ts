import { Browser, BrowserContext, Page } from "playwright";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execSync } from "node:child_process";
import logger from "@/logger";
import { Logger } from "pino";

export type BrowserLifecycleEventKind =
    | "page_created"
    | "page_crashed"
    | "page_closed"
    | "active_page_changed"
    | "context_closed"
    | "browser_disconnected";

export type PageCloseInitiator = "programmatic_agent" | "browser_ui_or_external";

export interface RuntimeDiagnostics {
    timestamp: string;
    memTotalMb?: number;
    memAvailableMb?: number;
    memFreeMb?: number;
    swapFreeMb?: number;
    cgroupMemoryCurrentMb?: number;
    cgroupMemoryMaxMb?: number;
    cgroupMemoryUsedPct?: number;
    devShmSizeMb?: number;
    devShmUsedMb?: number;
    devShmUsedPct?: number;
    chromeProcessCount?: number;
    chromeRendererCount?: number;
    pendingCrashDumps?: number;
    latestCrashDumpAgeMs?: number;
    loadAvg1?: number;
}

export interface BrowserLifecycleEventRecord {
    kind: BrowserLifecycleEventKind;
    timestamp: string;
    sessionId?: string;
    sessionLabel?: string;
    url?: string;
    pageIndex?: number;
    openTabCount?: number;
    browserConnected?: boolean;
    closeInitiator?: PageCloseInitiator;
    wasActivePage?: boolean;
    activePageUrlAtClose?: string;
    remainingTabUrls?: string[];
    activePageChangeReason?: string;
    likelyCause: string;
    diagnostics: RuntimeDiagnostics;
}

const lifecycleLogger: Logger = logger.child({ name: "browser_lifecycle" });

const programmaticPageCloses = new WeakSet<Page>();

let lastLifecycleEvent: BrowserLifecycleEventRecord | null = null;

export function getLastBrowserLifecycleEvent(): BrowserLifecycleEventRecord | null {
    return lastLifecycleEvent;
}

/** Mark a page before calling ``page.close()`` from agent code. */
export function markPageCloseProgrammatic(page: Page): void {
    programmaticPageCloses.add(page);
}

function readIntFromProcFile(filePath: string, key: string): number | undefined {
    try {
        const content = fs.readFileSync(filePath, "utf8");
        const line = content.split("\n").find((entry) => entry.startsWith(`${key}:`));
        if (!line) return undefined;
        return Math.floor(parseInt(line.split(/\s+/)[1], 10) / 1024);
    } catch {
        return undefined;
    }
}

function readCgroupMemory(field: "current" | "max"): number | undefined {
    const candidates = field === "current"
        ? [
            "/sys/fs/cgroup/memory.current",
            "/sys/fs/cgroup/memory/memory.usage_in_bytes",
        ]
        : [
            "/sys/fs/cgroup/memory.max",
            "/sys/fs/cgroup/memory/memory.limit_in_bytes",
        ];
    for (const candidate of candidates) {
        try {
            const raw = fs.readFileSync(candidate, "utf8").trim();
            if (raw === "max" || raw === "9223372036854771712") return undefined;
            const bytes = parseInt(raw, 10);
            if (Number.isFinite(bytes) && bytes > 0) {
                return Math.round(bytes / (1024 * 1024));
            }
        } catch {
            // try next path
        }
    }
    return undefined;
}

function readDevShmUsage(): { sizeMb?: number; usedMb?: number; usedPct?: number } {
    try {
        const output = execSync("df -k /dev/shm 2>/dev/null", { encoding: "utf8" }).trim();
        const line = output.split("\n")[1];
        if (!line) return {};
        const parts = line.split(/\s+/);
        const totalKb = parseInt(parts[1], 10);
        const usedKb = parseInt(parts[2], 10);
        if (!Number.isFinite(totalKb) || !Number.isFinite(usedKb) || totalKb <= 0) return {};
        return {
            sizeMb: Math.round(totalKb / 1024),
            usedMb: Math.round(usedKb / 1024),
            usedPct: Math.round((usedKb / totalKb) * 100),
        };
    } catch {
        return {};
    }
}

function readChromeProcessCounts(): { total?: number; renderers?: number } {
    try {
        const output = execSync("ps -eo args= 2>/dev/null", { encoding: "utf8" });
        const lines = output.split("\n");
        let total = 0;
        let renderers = 0;
        for (const line of lines) {
            if (!line.includes("chrome-linux/chrome")) continue;
            total += 1;
            if (line.includes("--type=renderer")) renderers += 1;
        }
        return { total, renderers };
    } catch {
        return {};
    }
}

function chromiumCrashPendingDirs(): string[] {
    const dirs = new Set<string>();

    const crashReportsRoot = process.env.CHROME_CRASH_REPORTS_DIR;
    if (crashReportsRoot) {
        dirs.add(path.join(crashReportsRoot, "pending"));
    }

    const configHomes = [
        process.env.CHROME_CONFIG_HOME,
        process.env.HOME,
        "/Unity",
        os.homedir(),
    ].filter((entry): entry is string => Boolean(entry && entry.trim()));

    for (const home of configHomes) {
        dirs.add(path.join(home, ".config", "chromium", "Crash Reports", "pending"));
        dirs.add(path.join(home, ".config", "google-chrome", "Crash Reports", "pending"));
    }

    return [...dirs];
}

function readCrashDumpStats(): { pending?: number; latestAgeMs?: number } {
    let pending = 0;
    let latestMtime = 0;
    for (const dir of chromiumCrashPendingDirs()) {
        try {
            for (const entry of fs.readdirSync(dir)) {
                if (!entry.endsWith(".dmp")) continue;
                pending += 1;
                const mtime = fs.statSync(path.join(dir, entry)).mtimeMs;
                latestMtime = Math.max(latestMtime, mtime);
            }
        } catch {
            // directory may not exist
        }
    }
    return {
        pending,
        latestAgeMs: latestMtime > 0 ? Date.now() - latestMtime : undefined,
    };
}

export function collectRuntimeDiagnostics(): RuntimeDiagnostics {
    const memTotalMb = readIntFromProcFile("/proc/meminfo", "MemTotal");
    const memAvailableMb = readIntFromProcFile("/proc/meminfo", "MemAvailable");
    const memFreeMb = readIntFromProcFile("/proc/meminfo", "MemFree");
    const swapFreeMb = readIntFromProcFile("/proc/meminfo", "SwapFree");
    const cgroupMemoryCurrentMb = readCgroupMemory("current");
    const cgroupMemoryMaxMb = readCgroupMemory("max");
    const devShm = readDevShmUsage();
    const chrome = readChromeProcessCounts();
    const crashDumps = readCrashDumpStats();

    let cgroupMemoryUsedPct: number | undefined;
    if (
        cgroupMemoryCurrentMb !== undefined
        && cgroupMemoryMaxMb !== undefined
        && cgroupMemoryMaxMb > 0
    ) {
        cgroupMemoryUsedPct = Math.round((cgroupMemoryCurrentMb / cgroupMemoryMaxMb) * 100);
    }

    let loadAvg1: number | undefined;
    try {
        loadAvg1 = parseFloat(fs.readFileSync("/proc/loadavg", "utf8").split(" ")[0]);
    } catch {
        // ignore
    }

    return {
        timestamp: new Date().toISOString(),
        memTotalMb,
        memAvailableMb,
        memFreeMb,
        swapFreeMb,
        cgroupMemoryCurrentMb,
        cgroupMemoryMaxMb,
        cgroupMemoryUsedPct,
        devShmSizeMb: devShm.sizeMb,
        devShmUsedMb: devShm.usedMb,
        devShmUsedPct: devShm.usedPct,
        chromeProcessCount: chrome.total,
        chromeRendererCount: chrome.renderers,
        pendingCrashDumps: crashDumps.pending,
        latestCrashDumpAgeMs: crashDumps.latestAgeMs,
        loadAvg1,
    };
}

function inferLikelyCause(
    kind: BrowserLifecycleEventKind,
    diagnostics: RuntimeDiagnostics,
    extra?: {
        closeInitiator?: PageCloseInitiator;
        wasActivePage?: boolean;
        remainingTabCount?: number;
    },
): string {
    const reasons: string[] = [];

    if (kind === "page_closed") {
        if (extra?.closeInitiator === "programmatic_agent") {
            reasons.push("agent_called_page_close");
        } else {
            reasons.push("browser_ui_or_external_close");
        }
        if (extra?.wasActivePage && (extra.remainingTabCount ?? 0) > 0) {
            reasons.push("automation_active_tab_closed_other_tabs_remain");
        }
        if (
            diagnostics.latestCrashDumpAgeMs !== undefined
            && diagnostics.latestCrashDumpAgeMs < 30_000
        ) {
            reasons.push("very_recent_chromium_crash_dump_near_close");
        }
    } else if (kind === "page_crashed") {
        reasons.push("chromium_renderer_crash");
    } else if (kind === "context_closed") {
        reasons.push("browser_context_closed");
    } else if (kind === "browser_disconnected") {
        reasons.push("browser_process_exited");
    }

    if (diagnostics.cgroupMemoryUsedPct !== undefined && diagnostics.cgroupMemoryUsedPct >= 90) {
        reasons.push("cgroup_memory_near_limit");
    }
    if (diagnostics.memAvailableMb !== undefined && diagnostics.memAvailableMb < 256) {
        reasons.push("low_mem_available");
    }
    if (diagnostics.devShmUsedPct !== undefined && diagnostics.devShmUsedPct >= 85) {
        reasons.push("dev_shm_nearly_full");
    }
    if (
        diagnostics.latestCrashDumpAgeMs !== undefined
        && diagnostics.latestCrashDumpAgeMs < 30_000
    ) {
        reasons.push("very_recent_chromium_crash_dump");
    }

    return reasons.join(",") || kind;
}

function safePageUrl(page: Page): string {
    try {
        return page.url();
    } catch {
        return "(url unavailable)";
    }
}

function listOpenTabUrls(context: BrowserContext): string[] {
    return context.pages().map((page) => {
        try {
            return page.url();
        } catch {
            return "(url unavailable)";
        }
    });
}

function appendLifecycleJsonl(record: BrowserLifecycleEventRecord): void {
    const logDir = process.env.MAGNITUDE_LOG_DIR;
    if (!logDir) return;
    try {
        fs.mkdirSync(logDir, { recursive: true });
        fs.appendFileSync(
            path.join(logDir, "browser_lifecycle.jsonl"),
            `${JSON.stringify(record)}\n`,
        );
    } catch (err) {
        lifecycleLogger.debug(
            { err: err instanceof Error ? err.message : String(err) },
            "Failed to append browser lifecycle JSONL",
        );
    }
}

function emitLifecycleEvent(record: BrowserLifecycleEventRecord): void {
    lastLifecycleEvent = record;
    const level = record.kind === "active_page_changed" || record.kind === "page_created"
        ? "info"
        : "warn";
    lifecycleLogger[level](record, `[browser-lifecycle] ${record.kind}`);
    appendLifecycleJsonl(record);
}

/** Log when TabManager changes the page Playwright automation targets. */
export function logActivePageChanged(
    context: BrowserContext,
    page: Page,
    reason: string,
    meta?: { sessionId?: string; sessionLabel?: string },
): void {
    const diagnostics = collectRuntimeDiagnostics();
    emitLifecycleEvent({
        kind: "active_page_changed",
        timestamp: new Date().toISOString(),
        sessionId: meta?.sessionId,
        sessionLabel: meta?.sessionLabel,
        url: safePageUrl(page),
        pageIndex: context.pages().indexOf(page),
        openTabCount: context.pages().length,
        activePageChangeReason: reason,
        likelyCause: reason,
        diagnostics,
    });
}

export class BrowserLifecycleObserver {
    private readonly attachedPages = new WeakSet<Page>();
    private readonly sessionId?: string;
    private readonly sessionLabel?: string;
    private readonly getActivePage?: () => Page | undefined;

    constructor(
        private readonly context: BrowserContext,
        options?: {
            sessionId?: string;
            sessionLabel?: string;
            getActivePage?: () => Page | undefined;
        },
    ) {
        this.sessionId = options?.sessionId;
        this.sessionLabel = options?.sessionLabel;
        this.getActivePage = options?.getActivePage;
    }

    attach(): void {
        const browser = this.context.browser();
        if (browser) {
            this.attachBrowser(browser);
        }

        this.context.on("close", () => {
            this.record("context_closed", {
                browserConnected: this.context.browser()?.isConnected(),
            });
        });

        this.context.on("page", (page) => this.attachPage(page, "context_page_event"));
        for (const page of this.context.pages()) {
            this.attachPage(page, "existing_page_at_attach");
        }

        lifecycleLogger.info(
            {
                sessionId: this.sessionId,
                sessionLabel: this.sessionLabel,
                openTabCount: this.context.pages().length,
            },
            "Browser lifecycle observer attached",
        );
    }

    private attachBrowser(browser: Browser): void {
        browser.on("disconnected", () => {
            this.record("browser_disconnected", {
                browserConnected: false,
            });
        });
    }

    private attachPage(page: Page, createdVia: string): void {
        if (this.attachedPages.has(page)) return;
        this.attachedPages.add(page);

        const pageIndex = this.context.pages().indexOf(page);

        this.record("page_created", {
            url: safePageUrl(page),
            pageIndex,
            openTabCount: this.context.pages().length,
            activePageChangeReason: createdVia,
        });

        page.on("crash", () => {
            this.record("page_crashed", {
                url: safePageUrl(page),
                pageIndex,
                openTabCount: this.context.pages().length,
                browserConnected: this.context.browser()?.isConnected(),
            });
        });

        page.on("close", () => {
            const closeInitiator: PageCloseInitiator = programmaticPageCloses.has(page)
                ? "programmatic_agent"
                : "browser_ui_or_external";
            programmaticPageCloses.delete(page);

            const activePage = this.getActivePage?.();
            const remainingTabUrls = listOpenTabUrls(this.context);

            this.record("page_closed", {
                url: safePageUrl(page),
                pageIndex,
                openTabCount: remainingTabUrls.length,
                browserConnected: this.context.browser()?.isConnected(),
                closeInitiator,
                wasActivePage: activePage === page,
                activePageUrlAtClose: activePage ? safePageUrl(activePage) : undefined,
                remainingTabUrls,
            });
        });

        page.on("pageerror", (error) => {
            lifecycleLogger.warn(
                {
                    sessionId: this.sessionId,
                    sessionLabel: this.sessionLabel,
                    url: safePageUrl(page),
                    pageIndex,
                    error: error instanceof Error ? error.message : String(error),
                },
                "[browser-lifecycle] page_javascript_error",
            );
        });
    }

    private record(
        kind: BrowserLifecycleEventKind,
        details: {
            url?: string;
            pageIndex?: number;
            openTabCount?: number;
            browserConnected?: boolean;
            closeInitiator?: PageCloseInitiator;
            wasActivePage?: boolean;
            activePageUrlAtClose?: string;
            remainingTabUrls?: string[];
            activePageChangeReason?: string;
        },
    ): void {
        const diagnostics = collectRuntimeDiagnostics();
        const record: BrowserLifecycleEventRecord = {
            kind,
            timestamp: new Date().toISOString(),
            sessionId: this.sessionId,
            sessionLabel: this.sessionLabel,
            url: details.url,
            pageIndex: details.pageIndex,
            openTabCount: details.openTabCount,
            browserConnected: details.browserConnected,
            closeInitiator: details.closeInitiator,
            wasActivePage: details.wasActivePage,
            activePageUrlAtClose: details.activePageUrlAtClose,
            remainingTabUrls: details.remainingTabUrls,
            activePageChangeReason: details.activePageChangeReason,
            likelyCause: inferLikelyCause(kind, diagnostics, {
                closeInitiator: details.closeInitiator,
                wasActivePage: details.wasActivePage,
                remainingTabCount: details.remainingTabUrls?.length,
            }),
            diagnostics,
        };
        emitLifecycleEvent(record);
    }
}

export function formatLastBrowserLifecycleHint(): string | null {
    const last = lastLifecycleEvent;
    if (!last) return null;
    const parts = [
        `Last browser lifecycle event: ${last.kind} at ${last.timestamp}`,
        last.url ? `url=${last.url}` : null,
        last.closeInitiator ? `closeInitiator=${last.closeInitiator}` : null,
        last.wasActivePage !== undefined ? `wasActivePage=${last.wasActivePage}` : null,
        last.remainingTabUrls?.length
            ? `remainingTabs=${last.remainingTabUrls.length}`
            : null,
        `likelyCause=${last.likelyCause}`,
        `memAvailableMb=${last.diagnostics.memAvailableMb ?? "?"}`,
    ].filter(Boolean);
    return parts.join(" ");
}
