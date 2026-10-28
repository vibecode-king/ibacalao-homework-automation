import assert from "node:assert/strict";
import { test } from "node:test";
import { isNonAcademicTitle, parseAcademicRow, roleForHeader, normalizeSchoolDate } from "../tableParse";

test("headers name the columns; the first cell is not assumed to be the title", () => {
  const row = parseAcademicRow(
    ["", "Materia", "Actividad", "Fecha de entrega", "Estado"],
    ["", "Historia", "Ensayo de Historia", "15/09/2026", "Pendiente"],
  );
  assert.equal(row?.title, "Ensayo de Historia");
  assert.equal(row?.subject, "Historia");
  assert.equal(row?.dueAt, "2026-09-15");
  assert.equal(row?.status, "Pendiente");
});

test("a header row is not an assignment", () => {
  assert.equal(
    parseAcademicRow(["Actividad", "Materia"], ["Actividad", "Materia"]),
    null,
  );
});

test("isNonAcademicTitle rejects table chrome labels", () => {
  assert.equal(isNonAcademicTitle("Actividad"), true);
  assert.equal(isNonAcademicTitle("Mensajería"), true);
  assert.equal(isNonAcademicTitle("Ensayo de Historia"), false);
});

test("an empty row is rejected", () => {
  assert.equal(parseAcademicRow(["Actividad", "Materia"], ["", ""]), null);
});

test("without headers, the first non-date cell is the title", () => {
  const row = parseAcademicRow([], ["Ensayo de Historia", "15/09/2026"]);
  assert.equal(row?.title, "Ensayo de Historia");
});

test("English headings map the same way", () => {
  const row = parseAcademicRow(
    ["Assignment", "Subject", "Due date", "Status"],
    ["Lab report", "Biology", "2026-09-20", "Assigned"],
  );
  assert.equal(row?.title, "Lab report");
  assert.equal(row?.subject, "Biology");
  assert.equal(row?.dueAt, "2026-09-20");
});

test("roleForHeader ignores checkbox columns", () => {
  assert.equal(roleForHeader("Select"), "ignore");
  assert.equal(roleForHeader("Actividad"), "title");
});

test("normalizeSchoolDate prefers day-month-year for numeric dates", () => {
  assert.equal(normalizeSchoolDate("15/09/2026"), "2026-09-15");
  assert.equal(normalizeSchoolDate("2026-09-18"), "2026-09-18");
});
