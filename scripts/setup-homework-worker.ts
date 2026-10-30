import { homedir } from "node:os";
import { setupWorker } from "../src/workerSetup";

try {
  if (process.platform !== "darwin" || typeof process.getuid !== "function") throw new Error("This setup is for the iBacalao Mac app.");
  if (Number(process.versions.node.split(".")[0]) < 22) throw new Error("Node.js 22 or newer is required for the bundled Homework worker.");
  const result = setupWorker({
    home: homedir(),
    bundleDir: __dirname,
    nodePath: process.execPath,
    baseUrl: process.env.IBACALAO_PAIR_URL ?? "",
    code: process.env.IBACALAO_PAIR_CODE ?? "",
    preferredCli: process.env.IBACALAO_AGENT_CLI,
    path: process.env.PATH ?? "",
    uid: process.getuid(),
  });
  console.log(`Homework worker connected or refreshed using ${result.cli}. Check Homework Overview for its connection status.`);
} catch (error) {
  console.error(`[homework-setup] ${error instanceof Error ? error.message : "Setup failed."}`);
  process.exitCode = 1;
}
