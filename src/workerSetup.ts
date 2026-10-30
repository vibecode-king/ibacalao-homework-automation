import { accessSync, chmodSync, constants, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { delimiter, dirname, isAbsolute, join } from "node:path";
import { spawnSync } from "node:child_process";

type Cli = "codex" | "claude";
type CommandResult = { status: number | null; error?: Error; stderr?: string | null };
type SetupOptions = {
  home: string;
  bundleDir: string;
  nodePath: string;
  baseUrl: string;
  code: string;
  preferredCli?: string;
  path: string;
  uid: number;
  run?: (command: string, args: string[], options: { cwd?: string; env?: NodeJS.ProcessEnv }) => CommandResult;
};

function executable(path: string): boolean {
  try { accessSync(path, constants.X_OK); return true; } catch { return false; }
}

function xml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

/** Pair and register the student's worker. The agent credential stays in .env. */
export function setupWorker(options: SetupOptions): { cli: Cli } {
  const { home, bundleDir, nodePath, baseUrl, code, path, uid } = options;
  if (!/^HWA-[A-F0-9]{24}$/i.test(code)) throw new Error("Invalid pairing code. Create a new code in Homework Overview.");
  let url: URL;
  try { url = new URL(baseUrl); } catch { throw new Error("Invalid iBacalao server URL."); }
  if (url.username || url.password || url.search || url.hash || (url.protocol !== "https:" && !(url.protocol === "http:" && ["localhost", "127.0.0.1"].includes(url.hostname)))) throw new Error("Invalid iBacalao server URL.");
  const pairScript = join(bundleDir, "homework-pair.cjs");
  const workerScript = join(bundleDir, "homework-worker.cjs");
  if (!executable(nodePath) || !existsSync(pairScript) || !existsSync(workerScript)) throw new Error("The app's Homework worker is not installed. Update the iBacalao app first.");
  const preferred = options.preferredCli?.trim().toLowerCase();
  if (preferred && preferred !== "codex" && preferred !== "claude") throw new Error("The AI command is not supported.");
  const paths = [...new Set([...path.split(delimiter), "/opt/homebrew/bin", "/usr/local/bin", join(home, ".local/bin")].filter(isAbsolute))];
  const candidates: Cli[] = preferred ? [preferred as Cli] : ["codex", "claude"];
  const cli = candidates.find((candidate) => paths.some((directory) => executable(join(directory, candidate))));
  if (!cli) throw new Error("A signed-in Codex or Claude command is needed on this Mac before connecting.");
  const cliDir = paths.find((directory) => executable(join(directory, cli)))!;
  const workerDir = join(home, ".ibacalao", "homework-agent");
  const plistFile = join(home, "Library", "LaunchAgents", "com.ibacalao.homework-agent.plist");
  const legacyPlist = join(home, "Library", "LaunchAgents", "com.ibacalao.homework-worker.plist");
  const launcher = join(workerDir, "start-worker.sh");
  if (existsSync(plistFile)) {
    const currentPlist = readFileSync(plistFile, "utf8");
    if (!currentPlist.includes("com.ibacalao.homework-agent") || !currentPlist.includes(xml(launcher))) {
      throw new Error("An unrelated launch agent uses the Homework worker label. Its configuration was left untouched.");
    }
  }
  if (existsSync(launcher)) {
    const currentLauncher = readFileSync(launcher, "utf8");
    if (!currentLauncher.includes("IBACALAO_WORKER_SCRIPT") || !currentLauncher.includes("IBACALAO_AGENT_TOKEN")) {
      throw new Error("An unrelated launcher exists in the Homework worker folder. Its configuration was left untouched.");
    }
  }
  mkdirSync(workerDir, { recursive: true, mode: 0o700 });
  mkdirSync(dirname(plistFile), { recursive: true, mode: 0o700 });
  const logFile = join(workerDir, "worker.log");
  writeFileSync(logFile, "", { flag: "a", mode: 0o600 });
  chmodSync(logFile, 0o600);
  const run = options.run ?? ((command, args, config) => spawnSync(command, args, { ...config, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 65_536 }));
  const { IBACALAO_AGENT_TOKEN: _token, IBACALAO_PAIR_CODE: _code, IBACALAO_AGENT_COMMAND: _command, ...safeEnv } = process.env;
  const paired = run(nodePath, [pairScript], { cwd: workerDir, env: { ...safeEnv, IBACALAO_PAIR_URL: url.origin, IBACALAO_PAIR_CODE: code } });
  if (paired.status !== 0) {
    const httpStatus = paired.stderr?.match(/\bHTTP (\d{3})\b/)?.[1];
    throw new Error(`Pairing failed (${httpStatus ? `HTTP ${httpStatus}` : `exit ${paired.status ?? "unknown"}`}). Create a new connection code and check the network and server URL.`);
  }
  const launchPath = [cliDir, ...paths].filter((value, index, all) => all.indexOf(value) === index).join(delimiter);
  const launcherBody = `#!/bin/sh\nfor candidate in "$IBACALAO_BUNDLED_NODE" "$IBACALAO_NODE_FALLBACK" "$IBACALAO_RUNTIME_ROOT"/*/node/bin/node; do\n  if [ -x "$candidate" ]; then\n    exec /usr/bin/env -u IBACALAO_AGENT_TOKEN -u IBACALAO_BASE_URL -u IBACALAO_AGENT_COMMAND -u IBACALAO_PAIR_CODE "$candidate" "$IBACALAO_WORKER_SCRIPT"\n  fi\ndone\necho 'Homework worker: Node runtime is unavailable.' >&2\nexit 1\n`;
  const createdLauncher = !existsSync(launcher);
  if (createdLauncher) writeFileSync(launcher, launcherBody, { flag: "wx", mode: 0o700 });
  const plist = `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>Label</key><string>com.ibacalao.homework-agent</string><key>ProgramArguments</key><array><string>/bin/sh</string><string>${xml(launcher)}</string></array><key>WorkingDirectory</key><string>${xml(workerDir)}</string><key>EnvironmentVariables</key><dict><key>PATH</key><string>${xml(launchPath)}</string><key>IBACALAO_AGENT_CLI</key><string>${cli}</string><key>IBACALAO_BUNDLED_NODE</key><string>${xml(join(bundleDir, "node/bin/node"))}</string><key>IBACALAO_NODE_FALLBACK</key><string>${xml(nodePath)}</string><key>IBACALAO_RUNTIME_ROOT</key><string>${xml(join(home, "Library/Application Support/iBacalao/WatcherRuntime"))}</string><key>IBACALAO_WORKER_SCRIPT</key><string>${xml(workerScript)}</string></dict><key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>StandardOutPath</key><string>${xml(logFile)}</string><key>StandardErrorPath</key><string>${xml(logFile)}</string></dict></plist>\n`;
  const createdPlist = !existsSync(plistFile);
  if (createdPlist) writeFileSync(plistFile, plist, { flag: "wx", mode: 0o600 });
  if (createdLauncher) chmodSync(launcher, 0o700);
  if (createdPlist) chmodSync(plistFile, 0o600);

  const label = "com.ibacalao.homework-agent";
  const legacyLabel = "com.ibacalao.homework-worker";
  const newStatus = run("/bin/launchctl", ["print", `gui/${uid}/${label}`], { env: safeEnv });
  const legacyStatus = existsSync(legacyPlist)
    ? run("/bin/launchctl", ["print", `gui/${uid}/${legacyLabel}`], { env: safeEnv })
    : { status: 1 };
  if (legacyStatus.status === 0) {
    const stopped = run("/bin/launchctl", ["bootout", `gui/${uid}`, legacyPlist], { env: safeEnv });
    if (stopped.status !== 0) throw new Error("The older Homework worker could not be paused. Its files were left in place; reconnect stopped before starting another worker.");
  }
  const started = newStatus.status === 0
    ? run("/bin/launchctl", ["kickstart", "-k", `gui/${uid}/${label}`], { env: safeEnv })
    : run("/bin/launchctl", ["bootstrap", `gui/${uid}`, plistFile], { env: safeEnv });
  if (started.status !== 0) throw new Error(`Pairing succeeded, but launchctl could not start the worker (exit ${started.status ?? "unknown"}). The private configuration was saved; create a fresh connection code and run setup again to retry.`);
  return { cli };
}
