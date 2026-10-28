import assert from "node:assert/strict";
import { test } from "node:test";
import { scoreMessageImportance } from "../messageImportance";

test("teacher + exam/deadline language ranks high", () => {
  const result = scoreMessageImportance({
    sender: "Profesora Ana",
    heading: "Examen de Biología mañana",
    body: "Recuerden estudiar capítulos 4 y 5 para la evaluación de primera hora.",
  });
  assert.equal(result.level, "high");
  assert.ok(result.score >= 65);
  assert.ok(result.reasons.includes("assessment_or_deadline"));
  assert.ok(result.reasons.includes("teacher_or_staff_sender"));
});

test("an actionable body with an academic attachment gets a boost", () => {
  const base = scoreMessageImportance({
    sender: "Profesor de Historia",
    heading: "Ensayo",
    body: "Completar el ensayo y entregarlo el viernes siguiendo las instrucciones adjuntas.",
  });
  const attached = scoreMessageImportance({
    sender: "Profesor de Historia",
    heading: "Ensayo",
    body: "Completar el ensayo y entregarlo el viernes siguiendo las instrucciones adjuntas.",
    attachments: ["rubrica-ensayo.pdf"],
  });
  assert.ok(attached.score > base.score);
  assert.ok(attached.reasons.includes("academic_attachment"));
});

test("generic promotional/social noise stays low", () => {
  const result = scoreMessageImportance({
    sender: "Comunidad escolar",
    heading: "Oferta especial y feria del sábado",
    body: "Promoción de uniformes durante la feria social del colegio.",
  });
  assert.equal(result.level, "low");
  assert.ok(result.reasons.includes("promotional_noise"));
});

test("content changes the score even when sender is identical", () => {
  const low = scoreMessageImportance({ sender: "Profesora Ana", heading: "Fotos", body: "Fotos del evento social." });
  const high = scoreMessageImportance({ sender: "Profesora Ana", heading: "Entrega IA mañana", body: "Entregar la IA antes de primera hora." });
  assert.ok(high.score > low.score);
});

test("an attachment alone cannot make weak content high priority", () => {
  const result = scoreMessageImportance({ heading: "Adjunto", body: "Ver adjunto.", attachments: ["documento.pdf"] });
  assert.notEqual(result.level, "high");
});
