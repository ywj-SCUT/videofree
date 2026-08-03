import { cp, mkdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

const root = process.cwd();
const standalone = path.join(root, 'web', '.next', 'standalone');
const serverEntry = path.join(standalone, 'web', 'server.js');
const resources = path.join(root, 'src-tauri', 'resources', 'server');
const compiledRuntime = path.join(root, 'dist-electron');
const binaryDirectory = path.join(root, 'src-tauri', 'binaries');
const targetTriple = 'x86_64-pc-windows-msvc';
const nodeSidecar = path.join(binaryDirectory, `videoget-node-${targetTriple}.exe`);

try {
  const entry = await stat(serverEntry);
  if (!entry.isFile() || entry.size === 0) throw new Error('empty standalone server');
} catch {
  throw new Error(`Next standalone server is missing: ${serverEntry}`);
}

await mkdir(resources, { recursive: true });
await mkdir(binaryDirectory, { recursive: true });
await cp(standalone, resources, { recursive: true, force: true });
await cp(compiledRuntime, path.join(resources, 'web', 'dist-electron'), { recursive: true, force: true });
await writeFile(path.join(resources, 'web', 'dist-electron', 'package.json'), '{"type":"module"}\n', 'utf8');
await mkdir(path.join(resources, 'web', '.next'), { recursive: true });
await writeFile(path.join(resources, 'web', 'package.json'), '{"type":"commonjs"}\n', 'utf8');
await cp(path.join(root, 'web', '.next', 'static'), path.join(resources, 'web', '.next', 'static'), { recursive: true, force: true });
await cp(path.join(root, 'web', 'public'), path.join(resources, 'web', 'public'), { recursive: true, force: true });
await cp(process.execPath, nodeSidecar, { force: true });

const [server, ruleWorker, node] = await Promise.all([
  stat(path.join(resources, 'web', 'server.js')),
  stat(path.join(resources, 'web', 'dist-electron', 'rule-worker.js')),
  stat(nodeSidecar),
]);
if (!server.size || !ruleWorker.size || node.size < 10_000_000) throw new Error('Tauri sidecar staging validation failed');
console.log(JSON.stringify({
  server: path.join(resources, 'web', 'server.js'),
  serverBytes: server.size,
  ruleWorker: path.join(resources, 'web', 'dist-electron', 'rule-worker.js'),
  ruleWorkerBytes: ruleWorker.size,
  node: nodeSidecar,
  nodeBytes: node.size,
}, null, 2));
