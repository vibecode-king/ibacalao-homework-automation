import { test } from "node:test";
import assert from "node:assert/strict";
import { buildDocxFromText, DOCX_MIME_TYPE } from "../src/docx";

test("builds a stored OOXML Word package from plain text and Markdown", () => {
  const bytes = buildDocxFromText("# Draft\n\nA & B < C.\n\n- first\n2. second");
  assert.equal(DOCX_MIME_TYPE, "application/vnd.openxmlformats-officedocument.wordprocessingml.document");
  assert.equal(bytes.readUInt32LE(0), 0x04034b50);
  const archiveText = bytes.toString("utf8");
  assert.match(archiveText, /\[Content_Types\]\.xml/);
  assert.match(archiveText, /_rels\/\.rels/);
  assert.match(archiveText, /word\/document\.xml/);
  assert.match(archiveText, /A &amp; B &lt; C\./);
  assert.match(archiveText, /Heading1/);
  assert.match(archiveText, /• first/);
});

test("rejects empty, HTML, and oversized drafts", () => {
  assert.throws(() => buildDocxFromText("  "), /empty/);
  assert.throws(() => buildDocxFromText("<p>not plain text</p>"), /HTML output/);
  assert.throws(() => buildDocxFromText("<!DOCTYPE html><html><body>x</body></html>"), /HTML output/);
  assert.throws(() => buildDocxFromText("x".repeat(500_001)), /500 KB/);
  assert.throws(() => buildDocxFromText(Array.from({ length: 20_001 }, () => "line").join("\n")), /20,000 line/);
});

test("defines the styles its paragraphs reference", () => {
  const archiveText = buildDocxFromText("# Title\n- item").toString("utf8");
  assert.match(archiveText, /word\/styles\.xml/);
  assert.match(archiveText, /w:styleId="Heading1"/);
  assert.match(archiveText, /w:styleId="ListParagraph"/);
});

test("accepts a draft that quotes HTML tags and escapes them", () => {
  const archiveText = buildDocxFromText("Use the <table> element for tabular data, not <div>.").toString("utf8");
  assert.match(archiveText, /&lt;table&gt;/);
});
