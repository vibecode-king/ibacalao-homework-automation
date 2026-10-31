import { execFile } from "node:child_process";
import { chmod } from "node:fs/promises";
import { userInfo } from "node:os";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

function windowsAccount(): string {
  const domain = process.env.USERDOMAIN?.trim();
  const user = process.env.USERNAME?.trim() || userInfo().username;
  return domain ? `${domain}\\${user}` : user;
}

/**
 * Owner-only access for the local worker token file. chmod 0600 is enough on
 * Unix; Windows ignores that mode, so apply an explicit ACL there.
 */
export async function protectSecretFile(path: string): Promise<void> {
  await chmod(path, 0o600);
  if (process.platform !== "win32") return;
  await execFileAsync("icacls", [
    path,
    "/inheritance:r",
    "/grant:r",
    `${windowsAccount()}:(F)`,
    "/grant:r",
    "*S-1-5-18:(F)",
  ], { windowsHide: true, timeout: 15_000 });
}
