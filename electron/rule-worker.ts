import { parentPort } from 'node:worker_threads';
import vm from 'node:vm';

interface StartMessage {
  type: 'start';
  script: string;
  operation: 'search' | 'detail' | 'play';
  input: unknown;
  config?: Record<string, unknown>;
}

interface ResponseMessage {
  type: 'response';
  id: number;
  ok: boolean;
  body?: string;
  error?: string;
}

if (!parentPort) throw new Error('规则 Worker 缺少父线程');

let requestId = 0;
const pending = new Map<number, { resolve: (value: string) => void; reject: (error: Error) => void }>();

function request(url: string, options: { method?: string; headers?: Record<string, string>; body?: string } = {}): Promise<string> {
  const id = ++requestId;
  return new Promise((resolve, reject) => {
    pending.set(id, { resolve, reject });
    parentPort?.postMessage({ type: 'request', id, url, options });
  });
}
Object.setPrototypeOf(request, null);
Object.freeze(request);

parentPort.on('message', async (message: StartMessage | ResponseMessage) => {
  if (message.type === 'response') {
    const entry = pending.get(message.id);
    if (!entry) return;
    pending.delete(message.id);
    if (message.ok) entry.resolve(message.body ?? '');
    else entry.reject(new Error(message.error ?? '规则请求失败'));
    return;
  }

  try {
    const sandbox = Object.create(null) as Record<string, unknown>;
    sandbox.module = { exports: {} };
    sandbox.exports = (sandbox.module as { exports: unknown }).exports;
    sandbox.console = Object.freeze({ log() {}, warn() {}, error() {} });
    sandbox.__input = structuredClone(message.input);
    sandbox.__config = structuredClone(message.config ?? {});
    sandbox.__request = request;
    const context = vm.createContext(sandbox, {
      name: 'VideoGET Rule Sandbox',
      codeGeneration: { strings: false, wasm: false },
    });
    const bootstrap = new vm.Script(`"use strict";\n${message.script}\n;globalThis.__rule = module.exports;`, {
      filename: 'videoget-rule.js',
    });
    bootstrap.runInContext(context, { timeout: 400 });
    const invoke = new vm.Script(`
      if (!globalThis.__rule || typeof globalThis.__rule[${JSON.stringify(message.operation)}] !== 'function') {
        throw new Error('规则缺少 ${message.operation} 函数');
      }
      globalThis.__result = Promise.resolve(globalThis.__rule[${JSON.stringify(message.operation)}](
        globalThis.__input,
        Object.freeze({ request: globalThis.__request, config: globalThis.__config })
      ));
    `, { filename: 'videoget-rule-invoke.js' });
    invoke.runInContext(context, { timeout: 400 });
    const result = await sandbox.__result;
    const serialized = JSON.stringify(result);
    if (serialized === undefined) throw new Error('规则没有返回结果');
    if (Buffer.byteLength(serialized) > 2 * 1024 * 1024) throw new Error('规则结果超过 2 MB');
    parentPort?.postMessage({ type: 'result', value: JSON.parse(serialized) });
  } catch (error) {
    parentPort?.postMessage({ type: 'error', error: error instanceof Error ? error.message : String(error) });
  }
});
