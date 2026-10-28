import assert from "node:assert/strict";
import { test } from "node:test";
import { classifyMessageUrgency } from "../messageUrgency";

test("promotional titles are low urgency", () => {
  const result = classifyMessageUrgency("Oferta especial de uniformes escolares");
  assert.equal(result.level, "low");
});

test("a near-term deadline reminder is high urgency", () => {
  const result = classifyMessageUrgency("Recordatorio: examen mañana primera hora");
  assert.equal(result.level, "high");
});

test("a bare exam keyword without a near-term reference is still high", () => {
  const result = classifyMessageUrgency("Examen de matemáticas la próxima semana");
  assert.equal(result.level, "high");
});

test("plain informational titles default to medium", () => {
  const result = classifyMessageUrgency("Actualización del calendario escolar");
  assert.equal(result.level, "medium");
});

test("checks the detail text too, not just the title", () => {
  const result = classifyMessageUrgency("Mensaje del profesor", "La entrega vence hoy");
  assert.equal(result.level, "high");
});
