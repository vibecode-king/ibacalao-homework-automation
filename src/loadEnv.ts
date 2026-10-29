// Loads ./.env (written by `npm run pair`) without overriding variables that are
// already set. Missing file or an older Node without loadEnvFile is fine.
try {
  (process as NodeJS.Process & { loadEnvFile?: (path?: string) => void }).loadEnvFile?.(".env");
} catch {
  // No .env file: rely on the real environment.
}
