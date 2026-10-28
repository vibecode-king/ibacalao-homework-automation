import { Redis } from "@upstash/redis";

let _redis: Redis | null = null;

// Lazily initialized singleton — avoids reconstructing the client on every
// function call while remaining safe in both Node.js and Edge runtimes.
export function redis(): Redis {
  return (_redis ??= Redis.fromEnv());
}
