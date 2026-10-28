import assert from "node:assert/strict";
import { test } from "node:test";
import { hypothesizeStructuredEndpoint, recordsFromAcademicJson } from "../structuredResponse";

test("assignment-shaped JSON endpoints are preferred over DOM guessing", () => {
  const hypothesis = hypothesizeStructuredEndpoint("/modules/activity/list", {
    type: "object",
    fields: {
      assignments: {
        type: "array",
        sampleShapes: [{ type: "object", fields: { title: "string", dueDate: "string", id: "string" } }],
      },
    },
  });
  assert.equal(hypothesis?.capability, "assignments");
  assert.ok((hypothesis?.confidence ?? 0) >= 0.45);
});

test("unrelated JSON is ignored rather than becoming fake school work", () => {
  assert.equal(
    hypothesizeStructuredEndpoint("/api/session/keepalive", {
      type: "object",
      fields: { ok: "boolean", t: "number" },
    }),
    null,
  );
});

test("sanitized academic JSON fixtures become records without treating headers as titles", () => {
  const records = recordsFromAcademicJson({
    assignments: [
      { id: "a1", title: "Ensayo de Historia", subject: "Historia", dueDate: "2026-09-15", teacher: "Ms Ruiz" },
      { id: "hdr", title: "Actividad", subject: "Materia" },
    ],
  }, "https://ukschool.learnbox.com.ec", "/modules/activity/:id");
  assert.equal(records.length, 1);
  assert.equal(records[0].title, "Ensayo de Historia");
  assert.equal(records[0].teacher, "Ms Ruiz");
  assert.equal(records[0].kind, "assignment");
});
