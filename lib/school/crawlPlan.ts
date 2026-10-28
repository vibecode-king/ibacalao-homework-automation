// lib/school/crawlPlan.ts
// The first reader of the platform graph: which page to crawl for a capability.
//
// The bundled adapter's hardcoded path is always the fallback. The graph only
// wins when a page has been read by a recipe often and reliably, and the caller
// still shadow-crawls the bundled path before trusting it (see learnbox.ts).

import { bestNodeForCapability, type PlatformNode } from "./platformGraph";
import type { SchoolActionCapability } from "./types";

const MIN_SUCCESS_RATE = 0.8;
const MIN_OBSERVATIONS = 3;

export function planCapabilityPath(
  nodes: PlatformNode[],
  capability: SchoolActionCapability,
  fallbackPath: string,
): { path: string; source: "graph" | "bundled" } {
  const trusted = nodes.filter((node) =>
    node.observationCount >= MIN_OBSERVATIONS
    && node.successCount / node.observationCount >= MIN_SUCCESS_RATE
    // One assignment's page is never where the whole collection lives.
    && !node.routeTemplate.split("/").includes(":id")
    && node.pageRole !== "detail"
    // Only pages a recipe actually read. A JSON endpoint guessed from its
    // schema is not a page the browser can be pointed at.
    && node.activeRecipeId !== null
  );
  const best = bestNodeForCapability(trusted, capability);
  return best ? { path: best.routeTemplate, source: "graph" } : { path: fallbackPath, source: "bundled" };
}
