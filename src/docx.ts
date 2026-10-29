const MIME_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
const MAX_TEXT_BYTES = 500_000;
const MAX_DOCUMENT_LINES = 20_000;

const CRC_TABLE = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let bit = 0; bit < 8; bit += 1) value = (value & 1) ? (0xedb88320 ^ (value >>> 1)) : (value >>> 1);
  return value >>> 0;
});

function crc32(bytes: Buffer): number {
  let value = 0xffffffff;
  for (const byte of bytes) value = CRC_TABLE[(value ^ byte) & 0xff] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}

const STYLES_XML = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
  + '<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>'
  + '<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>'
  + [[1, 32], [2, 28], [3, 24]].map(([level, size]) => '<w:style w:type="paragraph" w:styleId="Heading' + level + '"><w:name w:val="heading ' + level + '"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="' + (Number(level) - 1) + '"/></w:pPr><w:rPr><w:b/><w:sz w:val="' + size + '"/></w:rPr></w:style>').join("")
  + '<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720"/></w:pPr></w:style>'
  + '</w:styles>';

function xmlSafe(value: string): string {
  return value
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\ufffe\uffff]/g, "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&apos;");
}

function paragraph(line: string): string {
  const heading = line.match(/^(#{1,4})\s+(.+)$/);
  const list = line.match(/^\s*[-*+]\s+(.+)$/);
  const ordered = line.match(/^\s*\d+[.)]\s+(.+)$/);
  const content = heading?.[2] ?? list?.[1] ?? ordered?.[1] ?? line;
  const style = heading ? "<w:pPr><w:pStyle w:val=\"Heading" + Math.min(3, heading[1].length) + "\"/></w:pPr>" : "";
  const bullet = list ? "<w:pPr><w:pStyle w:val=\"ListParagraph\"/></w:pPr>" : "";
  const number = ordered ? "<w:pPr><w:pStyle w:val=\"ListParagraph\"/></w:pPr>" : "";
  const prefix = list ? "• " : ordered ? "▪ " : "";
  const text = xmlSafe(prefix + content).replace(/\t/g, "    ");
  return "<w:p>" + (style || bullet || number) + "<w:r><w:t xml:space=\"preserve\">" + text + "</w:t></w:r></w:p>";
}

function zip(entries: Array<{ name: string; content: string }>): Buffer {
  const local: Buffer[] = [];
  const central: Buffer[] = [];
  let offset = 0;
  const date = 0x21; // 1980-01-01
  for (const entry of entries) {
    const name = Buffer.from(entry.name, "utf8");
    const data = Buffer.from(entry.content, "utf8");
    const checksum = crc32(data);
    const header = Buffer.alloc(30);
    header.writeUInt32LE(0x04034b50, 0);
    header.writeUInt16LE(20, 4);
    header.writeUInt16LE(0x0800, 6);
    header.writeUInt16LE(0, 8);
    header.writeUInt16LE(0, 10);
    header.writeUInt16LE(date, 12);
    header.writeUInt32LE(checksum, 14);
    header.writeUInt32LE(data.length, 18);
    header.writeUInt32LE(data.length, 22);
    header.writeUInt16LE(name.length, 26);
    header.writeUInt16LE(0, 28);
    local.push(header, name, data);

    const directory = Buffer.alloc(46);
    directory.writeUInt32LE(0x02014b50, 0);
    directory.writeUInt16LE(20, 4);
    directory.writeUInt16LE(20, 6);
    directory.writeUInt16LE(0x0800, 8);
    directory.writeUInt16LE(0, 10);
    directory.writeUInt16LE(0, 12);
    directory.writeUInt16LE(date, 14);
    directory.writeUInt32LE(checksum, 16);
    directory.writeUInt32LE(data.length, 20);
    directory.writeUInt32LE(data.length, 24);
    directory.writeUInt16LE(name.length, 28);
    directory.writeUInt16LE(0, 30);
    directory.writeUInt16LE(0, 32);
    directory.writeUInt16LE(0, 34);
    directory.writeUInt16LE(0, 36);
    directory.writeUInt32LE(0, 38);
    directory.writeUInt32LE(offset, 42);
    central.push(directory, name);
    offset += header.length + name.length + data.length;
  }
  const centralBytes = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(0, 4);
  end.writeUInt16LE(0, 6);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralBytes.length, 12);
  end.writeUInt32LE(offset, 16);
  end.writeUInt16LE(0, 20);
  return Buffer.concat([...local, centralBytes, end]);
}

/**
 * True when the whole draft is an HTML page rather than text. Tags quoted inside
 * a normal draft (a web design essay, code samples) are escaped into the DOCX
 * and are fine.
 */
export function looksLikeHtmlDocument(text: string): boolean {
  const head = text.trimStart().slice(0, 400);
  return /^<!doctype\s+html/i.test(head) || /^<(?:html|body)\b/i.test(head) || /^<(?:div|p|h[1-6]|ul|ol|table|section|article)\b[^>]*>[\s\S]*<\/(?:div|p|h[1-6]|ul|ol|table|section|article)>\s*$/i.test(text.trim());
}

export function buildDocxFromText(text: string): Buffer {
  if (!text.trim()) throw new Error("The generated document is empty.");
  if (looksLikeHtmlDocument(text)) {
    throw new Error("HTML output is not accepted. Return plain text or Markdown.");
  }
  if (Buffer.byteLength(text, "utf8") > MAX_TEXT_BYTES) throw new Error("The generated document exceeds the 500 KB limit.");
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  if (lines.length > MAX_DOCUMENT_LINES) throw new Error("The generated document exceeds the 20,000 line limit.");
  const body = lines.map((line) => line ? paragraph(line) : "<w:p/>").join("");
  const document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>" + body + "<w:sectPr/></w:body></w:document>";
  const bytes = zip([
    { name: "[Content_Types].xml", content: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>' },
    { name: "_rels/.rels", content: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>' },
    { name: "word/_rels/document.xml.rels", content: '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>' },
    { name: "word/styles.xml", content: STYLES_XML },
    { name: "word/document.xml", content: document },
  ]);
  if (bytes.byteLength > 12 * 1024 * 1024) throw new Error("The generated Word document exceeds the 12 MiB limit.");
  return bytes;
}

export { MIME_TYPE as DOCX_MIME_TYPE };
