// lib/school/tableParse.ts
// Turn a school table row into academic fields by reading the headings.
//
// Treat-the-first-cell-as-the-title is how Learnbox assignments used to be
// extracted. That is wrong on any table whose first column is a checkbox,
// a subject, a date, or a status. Headers are the contract the page already
// publishes; we just have to honour them.

export type AcademicRow = {
  title: string;
  subject?: string;
  dueAt?: string;
  status?: string;
  grade?: string;
};

const TITLE_HEADER = /\b(title|actividad|activity|assignment|tarea|trabajo|nombre|name|descripci[oó]n)\b/i;
const SUBJECT_HEADER = /\b(subject|materia|asignatura|curso|course|class|grupo)\b/i;
const DUE_HEADER = /\b(due|deadline|fecha|vencimiento|entrega|vence)\b/i;
const STATUS_HEADER = /\b(status|estado|progress|progreso)\b/i;
const GRADE_HEADER = /\b(grade|nota|calificaci[oó]n|mark|score|promedio|equivalencia)\b/i;
const SKIP_HEADER = /\b(select|checkbox|#|n[oº°]|actions?|acciones)\b/i;

/** Header row, pagination, or a row with no academic title. */
const NON_ACADEMIC_TITLE = /^(?:title|actividad|assignment|tarea|subject|materia|fecha|status|estado)$/i;
const NAV_CHROME_TITLE = /^(?:mensajer[ií]a|agenda|inicio|home|dashboard|calendar|calendario|perfil|profile|settings|configuraci[oó]n)$/i;

/** Table header cells and chrome labels must not become assignments. */
export function isNonAcademicTitle(value: string): boolean {
  const trimmed = value.replace(/\s+/g, " ").trim();
  return !trimmed || NON_ACADEMIC_TITLE.test(trimmed) || NAV_CHROME_TITLE.test(trimmed);
}

export type ColumnRole = "title" | "subject" | "dueAt" | "status" | "grade" | "ignore";

export function roleForHeader(header: string): ColumnRole {
  const trimmed = header.replace(/\s+/g, " ").trim();
  if (!trimmed || SKIP_HEADER.test(trimmed)) return "ignore";
  if (TITLE_HEADER.test(trimmed)) return "title";
  if (SUBJECT_HEADER.test(trimmed)) return "subject";
  if (DUE_HEADER.test(trimmed)) return "dueAt";
  if (STATUS_HEADER.test(trimmed)) return "status";
  if (GRADE_HEADER.test(trimmed)) return "grade";
  return "ignore";
}

function cell(value: string | undefined): string | undefined {
  const trimmed = value?.replace(/\s+/g, " ").trim();
  return trimmed || undefined;
}

function looksLikeDate(value: string): boolean {
  if (/\d{1,4}[/-]\d{1,2}[/-]\d{1,4}/.test(value)) return true;
  return Number.isFinite(Date.parse(value));
}

/** Prefer ISO so later consumers don't have to guess day-vs-month order. */
export function normalizeSchoolDate(value: string): string | undefined {
  const trimmed = value.trim();
  const iso = trimmed.match(/^(\d{4})-(\d{2})-(\d{2})/);
  if (iso) return `${iso[1]}-${iso[2]}-${iso[3]}`;
  const dmy = trimmed.match(/^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$/);
  if (dmy) {
    const day = dmy[1].padStart(2, "0");
    const month = dmy[2].padStart(2, "0");
    return `${dmy[3]}-${month}-${day}`;
  }
  const ms = Date.parse(trimmed);
  return Number.isFinite(ms) ? new Date(ms).toISOString().slice(0, 10) : trimmed;
}

/**
 * Maps one table row against its headings. Falls back to "first non-empty
 * cell is the title" only when the table published no usable title column —
 * never when a heading already named a different first column.
 */
export function parseAcademicRow(headers: string[], cells: string[]): AcademicRow | null {
  const roles = headers.map(roleForHeader);
  const titleIndex = roles.indexOf("title");
  const byRole = (role: ColumnRole): string | undefined => {
    const index = roles.indexOf(role);
    return index >= 0 ? cell(cells[index]) : undefined;
  };

  let title = titleIndex >= 0 ? cell(cells[titleIndex]) : undefined;
  if (title && isNonAcademicTitle(title)) title = undefined;
  if (!title) {
    // No title column: skip checkbox/date/status-looking leading cells.
    for (let index = 0; index < cells.length; index += 1) {
      if (roles[index] && roles[index] !== "ignore" && roles[index] !== "title") continue;
      const value = cell(cells[index]);
      if (!value) continue;
      if (looksLikeDate(value)) continue;
      if (NON_ACADEMIC_TITLE.test(value)) continue;
      title = value;
      break;
    }
  }
  if (!title || NON_ACADEMIC_TITLE.test(title)) return null;

  const subject = byRole("subject");
  const dueRaw = byRole("dueAt");
  const status = byRole("status");
  const grade = byRole("grade");
  return {
    title,
    ...(subject ? { subject } : {}),
    ...(dueRaw ? { dueAt: normalizeSchoolDate(dueRaw) } : {}),
    ...(status ? { status } : {}),
    ...(grade ? { grade } : {}),
  };
}
