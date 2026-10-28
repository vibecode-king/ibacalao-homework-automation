import { test } from "node:test";
import assert from "node:assert/strict";
import {
  detectFailClosedSignal,
  isDestructiveControl,
  isOriginAllowed,
  isPasswordField,
  shouldStopNavigation,
} from "../uivisionSafety";

test("never types into a password field", () => {
  assert.equal(isPasswordField("password"), true);
  assert.equal(isPasswordField("Password"), true);
  assert.equal(isPasswordField("text"), false);
});

test("never clicks delete/remove/send/submit controls, EN and ES", () => {
  for (const label of ["Delete assignment", "Remove", "Send message", "Submit", "Eliminar", "Enviar"]) {
    assert.equal(isDestructiveControl(label), true, label);
  }
  assert.equal(isDestructiveControl("View assignment"), false);
});

test("detects CAPTCHA and 2FA challenge copy", () => {
  assert.equal(detectFailClosedSignal("Please complete the CAPTCHA below"), "challenge");
  assert.equal(detectFailClosedSignal("Verifica que no eres un robot"), "challenge");
  assert.equal(detectFailClosedSignal("Enter your two-factor authentication code"), "challenge");
  assert.equal(detectFailClosedSignal("Welcome to your dashboard"), null);
});

test("bounds the challenge scan so an unbounded page never gets fully scanned", () => {
  const huge = `${"x".repeat(30_000)}captcha`;
  assert.equal(detectFailClosedSignal(huge), null);
});

test("only the connected school origin and approved redirects are allowed", () => {
  assert.equal(isOriginAllowed("https://school.example.com/dashboard", "https://school.example.com"), true);
  assert.equal(
    isOriginAllowed("https://login.microsoftonline.com/oauth", "https://school.example.com", ["https://login.microsoftonline.com"]),
    true,
  );
  assert.equal(isOriginAllowed("https://evil.example.com", "https://school.example.com"), false);
  assert.equal(isOriginAllowed("http://school.example.com", "https://school.example.com"), false);
});

test("shouldStopNavigation stops on off-origin before it even reads page text", () => {
  const result = shouldStopNavigation({
    url: "https://evil.example.com",
    pageText: "nothing suspicious",
    schoolOrigin: "https://school.example.com",
  });
  assert.deepEqual(result, { stop: true, reason: "origin_not_allowed" });
});

test("shouldStopNavigation stops on a challenge signal while on-origin", () => {
  const result = shouldStopNavigation({
    url: "https://school.example.com/verify",
    pageText: "Please verify you are human",
    schoolOrigin: "https://school.example.com",
  });
  assert.deepEqual(result, { stop: true, reason: "challenge" });
});

test("shouldStopNavigation stops on a login wall via password field, independent of page text", () => {
  const result = shouldStopNavigation({
    url: "https://school.example.com/login",
    pageText: "Nombre de usuario / Contraseña",
    schoolOrigin: "https://school.example.com",
    hasPasswordField: true,
  });
  assert.deepEqual(result, { stop: true, reason: "login_wall" });
});

test("shouldStopNavigation allows an ordinary on-origin page", () => {
  const result = shouldStopNavigation({
    url: "https://school.example.com/assignments",
    pageText: "Your assignments",
    schoolOrigin: "https://school.example.com",
  });
  assert.deepEqual(result, { stop: false });
});
