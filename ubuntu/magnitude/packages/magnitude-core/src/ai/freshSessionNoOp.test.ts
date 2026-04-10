import { describe, expect, test, beforeAll } from 'bun:test';
import { ModelHarness } from './modelHarness';
import { AgentMemory } from '@/memory/agentMemory';
import { Observation } from '@/memory/observation';
import { webActions } from '@/actions/webActions';
import { taskActions } from '@/actions/taskActions';
import { AgentContext } from '@/ai/baml_client';
import dotenv from 'dotenv';
import path from 'path';

dotenv.config({ path: path.resolve(process.cwd(), '../../../.env') });

const FRESH_SESSION_NOTE =
  'This is a freshly created browser session — the browser is already open and loaded. '
  + 'If the task is simply asking to open a browser, open a new browser window, or launch a browser, '
  + 'this has already been accomplished. Return an empty actions list.';

function getLLMConfig(): { provider: string; options: Record<string, any> } | null {
  if (process.env.UNITY_COMMS_URL && process.env.UNIFY_KEY) {
    return {
      provider: 'openai-generic',
      options: {
        model: 'claude-4.6-opus@anthropic',
        baseUrl: `${process.env.UNITY_COMMS_URL}/unillm`,
        headers: { 'Authorization': `Bearer ${process.env.UNIFY_KEY}` },
        temperature: 0.0,
      },
    };
  }
  if (process.env.ANTHROPIC_API_KEY) {
    return {
      provider: 'anthropic',
      options: {
        model: 'claude-sonnet-4-20250514',
        apiKey: process.env.ANTHROPIC_API_KEY,
        temperature: 0.0,
      },
    };
  }
  return null;
}

async function buildContext(memory: AgentMemory): Promise<AgentContext> {
  const messages = await memory.render();
  return {
    instructions: memory.instructions,
    observationContent: messages,
    connectorInstructions: [],
  };
}

const actActions = [...webActions, ...taskActions]
  .filter(a => !a.name.startsWith('task:'));

describe('fresh session no-op (LLM eval)', () => {
  let harness: ModelHarness;
  let skip: boolean;

  beforeAll(async () => {
    const config = getLLMConfig();
    if (!config) {
      skip = true;
      return;
    }
    skip = false;
    harness = new ModelHarness({ llm: config as any });
    await harness.setup();
  });

  test('LLM returns no browser-mutating actions for "Open the browser" on a fresh session', async () => {
    if (skip) {
      console.log('Skipping: no LLM credentials available');
      return;
    }

    const memory = new AgentMemory({ promptCaching: false });
    memory.recordObservation(new Observation(
      'thought',
      'user',
      FRESH_SESSION_NOTE,
    ));

    const context = await buildContext(memory);
    const { reasoning, actions } = await harness.partialAct(
      context,
      'Open a new browser window',
      [],
      actActions,
    );

    console.log('Reasoning:', reasoning);
    console.log('Actions:', JSON.stringify(actions));

    const browserMutatingActions = (actions ?? []).filter(
      (a: any) => !['wait'].includes(a.variant),
    );
    expect(browserMutatingActions).toEqual([]);
  }, 60_000);

  test('LLM still plans real actions when task has real work, even on fresh session', async () => {
    if (skip) {
      console.log('Skipping: no LLM credentials available');
      return;
    }

    const memory = new AgentMemory({ promptCaching: false });
    memory.recordObservation(new Observation(
      'thought',
      'user',
      FRESH_SESSION_NOTE,
    ));

    const context = await buildContext(memory);
    const { reasoning, actions } = await harness.partialAct(
      context,
      'Navigate to costar.com and click the Login button',
      [],
      actActions,
    );

    console.log('Reasoning:', reasoning);
    console.log('Actions:', JSON.stringify(actions));

    const hasRealAction = (actions ?? []).some(
      (a: any) => a.variant === 'browser:nav' || a.variant === 'mouse:click',
    );
    expect(hasRealAction).toBe(true);
  }, 60_000);
});
