
// Common interfaces that can be used anywhere
// Goal is not to expose internals but provide all necessary info in events

import { Action } from "@/actions/types";
import { ActOptions } from "@/agent";
import { LLMClientIdentifier, ModelUsage } from "@/ai/types";
import { LLMClient } from "@/ai/types";

export interface PlanDebugData {
    reasoning: string;
    actions: Action[];
    planningMs: number;
    observationCount: number;
}

export interface ActionDebugData {
    action: Action;
    index: number;
    totalActions: number;
    executionMs: number;
    error?: string;
}

export interface ScreenshotDebugData {
    label: string;
    base64: string;
    width?: number;
    height?: number;
}

export interface CoordinateDebugData {
    action: string;
    rawCoords: { x: number; y: number };
    transformedCoords: { x: number; y: number };
    viewport?: { width: number; height: number };
    virtualScreen?: { width: number; height: number };
}

export interface AgentEvents {
    'start': () => void;
    'stop': () => void;

    'thought': (thought: string) => void;

    'actStarted': (task: string, options: ActOptions) => void;
    'actDone': (task: string,  options: ActOptions) => void;
    
    'actionStarted': (action: Action) => void;
    'actionDone': (action: Action) => void;

    'pause': () => void;
    'resume': () => void;

    'tokensUsed': (usage: ModelUsage) => void;

    'debugPlan': (data: PlanDebugData) => void;
    'debugAction': (data: ActionDebugData) => void;
    'debugScreenshot': (data: ScreenshotDebugData) => void;
    'debugCoordinates': (data: CoordinateDebugData) => void;
}