// The connector should know more about a school each day without becoming
// unstable: the graph accumulates evidence, it does not change behavior.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { DatabaseSync } from "node:sqlite";
import { openSchoolJournal } from "../journal";
import {
  bestNodeForCapability,
  ensurePlatformGraphSchema,
  isGraphablePath,
  readPlatformEdges,
  readPlatformNodes,
  recordPlatformEdges,
  recordPlatformNode,
  routeTemplate,
} from "../platformGraph";
import type { NavigationEdgeObservation } from "../evidence";

const SOURCE = "vendor:managebac";

function withGraph(run: (db: DatabaseSync) => void): void {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-graph-"));
  const db = openSchoolJournal(join(root, "school.db"));
  try {
    ensurePlatformGraphSchema(db);
    run(db);
  } finally {
    db.close();
    rmSync(root, { recursive: true, force: true });
  }
}

function edge(fromPath: string, toPath: string, relationship: "detail" | "attachment"): NavigationEdgeObservation {
  return {
    sourceKey: SOURCE,
    origin: "https://school.example",
    observedAt: "2026-09-13T15:00:00.000Z",
    payload: { kind: "navigation-edge", fromPath, toPath, relationship },
  };
}

test("every assignment the student opens is the same kind of page", () => {
  assert.equal(routeTemplate("/assignments/12345"), "/assignments/:id");
  assert.equal(routeTemplate("/assignments/67890"), "/assignments/:id");
  assert.equal(routeTemplate("/student/6f1c9f3a-8f21-4b2e-9a77-2b7c1f0d9e55/grades"), "/student/:id/grades");
  assert.equal(routeTemplate("/assignments?page=2"), "/assignments");
  assert.equal(routeTemplate("/messages"), "/messages");
  assert.equal(routeTemplate("/modules/activity/fStudentCalendarActivity"), "/modules/activity/fStudentCalendarActivity");
  assert.equal(routeTemplate("/files/aB3dE5fG7hJ9kL1mN3pQ5r"), "/files/:id");
});

test("a name after a person-collection segment templates even without a digit", () => {
  assert.equal(routeTemplate("/alumnos/juanperez"), "/alumnos/:id");
  assert.equal(routeTemplate("/students/maria-gomez"), "/students/:id");
  assert.equal(routeTemplate("/teachers/profesor-lopez/schedule"), "/teachers/:id/schedule");
  // Not a person collection: page name stays a page name.
  assert.equal(routeTemplate("/profile/settings"), "/profile/:id");
  assert.equal(routeTemplate("/dashboard/students"), "/dashboard/students");
});

test("polling RPCs and assets never become graph nodes", () => {
  assert.equal(isGraphablePath("/rpc/remoteValidation/message/checkUserMessages.rpc"), false);
  assert.equal(isGraphablePath("/api/x.json"), false);
  assert.equal(isGraphablePath("/static/app.js"), false);
  assert.equal(isGraphablePath("/student/assignments"), true);
  assert.equal(isGraphablePath("/modules/message/fInbox"), true);
  withGraph((db) => {
    recordPlatformNode(db, SOURCE, {
      path: "/rpc/remoteValidation/message/checkUserMessages.rpc",
      pageRole: "collection",
      capability: "messages",
      observedAt: "2026-09-13T15:00:00.000Z",
      succeeded: true,
    });
    assert.equal(readPlatformNodes(db, SOURCE).length, 0);
  });
});

test("repeat visits refine one node instead of creating many", () => {
  withGraph((db) => {
    for (const path of ["/assignments/1001", "/assignments/1002", "/assignments/1003"]) {
      recordPlatformNode(db, SOURCE, {
        path,
        pageRole: "detail",
        capability: "assignments",
        observedAt: "2026-09-13T15:00:00.000Z",
        succeeded: true,
      });
    }

    const nodes = readPlatformNodes(db, SOURCE);
    assert.equal(nodes.length, 1);
    assert.equal(nodes[0].routeTemplate, "/assignments/:id");
    assert.equal(nodes[0].observationCount, 3);
    assert.equal(nodes[0].successCount, 3);
  });
});

test("a page that sometimes fails keeps both halves of its history", () => {
  withGraph((db) => {
    recordPlatformNode(db, SOURCE, {
      path: "/messages",
      pageRole: "messages",
      capability: "messages",
      observedAt: "2026-09-13T15:00:00.000Z",
      succeeded: true,
      fieldCompleteness: 0.8,
    });
    recordPlatformNode(db, SOURCE, {
      path: "/messages",
      pageRole: "messages",
      observedAt: "2026-09-13T16:00:00.000Z",
      succeeded: false,
      fieldCompleteness: 0.2,
    });

    const [node] = readPlatformNodes(db, SOURCE);
    assert.equal(node.observationCount, 2);
    assert.equal(node.successCount, 1);
    assert.equal(node.failureCount, 1);
    assert.equal(node.lastSuccessAt, "2026-09-13T15:00:00.000Z");
    assert.equal(node.lastFailureAt, "2026-09-13T16:00:00.000Z");
    // Capability learned once is not forgotten by a later failed read.
    assert.equal(node.capability, "messages");
    assert.ok(node.fieldCompleteness > 0.2 && node.fieldCompleteness < 0.8);
  });
});

test("navigation the student actually did becomes structure", () => {
  withGraph((db) => {
    recordPlatformEdges(db, SOURCE, [
      edge("/assignments", "/assignments/1001", "detail"),
      edge("/assignments", "/assignments/1002", "detail"),
      edge("/assignments/1001", "/files/rubric.pdf", "attachment"),
    ]);

    const edges = readPlatformEdges(db, SOURCE);
    assert.equal(edges.length, 2);

    const collectionToDetail = edges.find((entry) => entry.toTemplate === "/assignments/:id");
    assert.equal(collectionToDetail?.relationship, "detail");
    // Two different assignments opened from the list is two sightings of one edge.
    assert.equal(collectionToDetail?.observationCount, 2);

    const attachment = edges.find((entry) => entry.relationship === "attachment");
    assert.equal(attachment?.fromTemplate, "/assignments/:id");
  });
});

test("the most reliable page for a capability wins", () => {
  withGraph((db) => {
    recordPlatformNode(db, SOURCE, {
      path: "/dashboard",
      pageRole: "collection",
      capability: "assignments",
      observedAt: "2026-09-13T15:00:00.000Z",
      succeeded: true,
    });
    for (const succeeded of [true, false, false]) {
      recordPlatformNode(db, SOURCE, {
        path: "/calendar",
        pageRole: "collection",
        capability: "assignments",
        observedAt: "2026-09-13T15:00:00.000Z",
        succeeded,
      });
    }

    const nodes = readPlatformNodes(db, SOURCE);
    assert.equal(bestNodeForCapability(nodes, "assignments")?.routeTemplate, "/dashboard");
    assert.equal(bestNodeForCapability(nodes, "grades"), null);
  });
});

test("graph knowledge survives a restart", () => {
  const root = mkdtempSync(join(tmpdir(), "ibacalao-graph-restart-"));
  const file = join(root, "school.db");
  try {
    const first = openSchoolJournal(file);
    ensurePlatformGraphSchema(first);
    recordPlatformNode(first, SOURCE, {
      path: "/assignments",
      pageRole: "collection",
      capability: "assignments",
      observedAt: "2026-09-13T15:00:00.000Z",
      succeeded: true,
    });
    first.close();

    const second = openSchoolJournal(file);
    ensurePlatformGraphSchema(second);
    assert.equal(readPlatformNodes(second, SOURCE).length, 1);
    second.close();
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
