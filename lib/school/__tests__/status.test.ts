import { test } from "node:test";
import assert from "node:assert/strict";
import { higherPriorityAction, normalizeSchoolConnectionStatus, overlayPassiveStatus, statusNeedsLearningAction, statusNeedsStudentAction } from "../status";

const healthy = {
  sourceKey: "vendor:managebac",
  platformLabel: "ManageBac",
  schoolLabel: "Test School",
  connected: true,
  syncMode: "verified_background",
  actionReason: "none",
  recipe: { state: "healthy", confidence: 1 },
};

test("normalizes a healthy school status", () => {
  const status = normalizeSchoolConnectionStatus(healthy);
  assert.equal(status?.platformLabel, "ManageBac");
  assert.equal(status?.recipe?.confidence, 1);
  assert.equal(statusNeedsStudentAction(status!), false);
});

test("rejects malformed source and unknown sync modes", () => {
  assert.equal(normalizeSchoolConnectionStatus({ ...healthy, sourceKey: "https://school.test" }), null);
  assert.equal(normalizeSchoolConnectionStatus({ ...healthy, syncMode: "stealth_browser" }), null);
});

test("filters unknown missing capabilities", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    actionReason: "manual_learning_required",
    missingCapabilities: ["assignments", "passwords", "grades"],
  });
  assert.deepEqual(status?.missingCapabilities, ["assignments", "grades"]);
  assert.equal(statusNeedsStudentAction(status!), true);
});

test("missing required capabilities expose the learning action even when actionReason is none", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    actionReason: "none",
    missingCapabilities: ["assignments", "messages"],
  });
  assert.ok(status);
  assert.equal(statusNeedsLearningAction(status), true);
  assert.equal(statusNeedsStudentAction(status), true);
});

test("higher-priority action states suppress capability-learning fallback", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    actionReason: "reauth_required",
    missingCapabilities: ["assignments"],
  });
  assert.ok(status);
  assert.equal(statusNeedsLearningAction(status), false);
  assert.equal(statusNeedsStudentAction(status), true);
});

test("reauth outranks every lower-priority state", () => {
  assert.equal(higherPriorityAction("manual_learning_required", "reauth_required"), "reauth_required");
  assert.equal(higherPriorityAction("challenge_paused", "recipe_repairing"), "challenge_paused");
});

test("passive overlay keeps reauth/challenge instead of stale", () => {
  const reauth = normalizeSchoolConnectionStatus({
    ...healthy,
    connected: false,
    actionReason: "reauth_required",
  });
  const stale = normalizeSchoolConnectionStatus({
    ...healthy,
    connected: false,
    actionReason: "connector_stale",
    syncMode: "passive_browser",
  });
  assert.ok(reauth && stale);
  assert.equal(overlayPassiveStatus(reauth, stale).actionReason, "reauth_required");
  assert.equal(overlayPassiveStatus(stale, stale).actionReason, "connector_stale");
  assert.equal(overlayPassiveStatus(null, stale).actionReason, "connector_stale");
});


test("an incomplete collection still needs student attention", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    actionReason: "none",
    incompleteCapabilities: ["assignments", "passwords"],
  });
  assert.deepEqual(status?.incompleteCapabilities, ["assignments"]);
  assert.equal(statusNeedsLearningAction(status!), false);
  assert.equal(statusNeedsStudentAction(status!), true);
});

test("stale connector state is normalized, outranks learning, and requires attention", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    connected: false,
    actionReason: "connector_stale",
    recipe: { state: "stale", confidence: 1 },
  });
  assert.ok(status);
  assert.equal(statusNeedsStudentAction(status), true);
  assert.equal(statusNeedsLearningAction(status), false);
  assert.equal(higherPriorityAction("manual_learning_required", "connector_stale"), "connector_stale");
});

test("per-capability health survives status.json round-trip", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    capabilities: [
      {
        capability: "messages",
        state: "partial",
        method: "active_crawl",
        consecutiveFailures: 0,
        completeness: "partial",
      },
      { capability: "passwords", state: "healthy", method: "dom_recipe", consecutiveFailures: 0 },
      {
        capability: "grades",
        state: "reauth_required",
        method: "active_crawl",
        consecutiveFailures: 1,
      },
    ],
  });
  assert.equal(status?.capabilities?.length, 2);
  assert.equal(status?.capabilities?.[0].state, "partial");
  assert.equal(status?.capabilities?.[1].state, "reauth_required");
  assert.equal(statusNeedsStudentAction(status!), true);
});

test("chainState survives status.json round-trip", () => {
  const status = normalizeSchoolConnectionStatus({
    ...healthy,
    chainState: "daemon_not_consuming",
  });
  assert.equal(status?.chainState, "daemon_not_consuming");
});
