/** Record kinds the watcher can report. Mirrors the server-side Dispatch kinds. */
export type DispatchRecordKind = "assignment" | "message" | "grade" | "submission" | "deadline";
import type { SchoolSourceKey } from "./source";

export type SchoolSyncMode =
  | "official_api"
  | "verified_background"
  | "passive_browser"
  | "manual_page"
  | "visual_fallback";

export type SchoolActionReason =
  | "none"
  | "reauth_required"
  | "manual_learning_required"
  | "challenge_paused"
  | "connector_stale"
  | "recipe_repairing";

export type SchoolActionCapability =
  | "assignments"
  | "messages"
  | "grades"
  | "deadlines"
  | "submissions";

export type SchoolRecipeState = "missing" | "healthy" | "repairing" | "stale";

export type SchoolConnectionStatus = {
  sourceKey: SchoolSourceKey;
  platformLabel: string;
  schoolLabel?: string;
  connected: boolean;
  syncMode: SchoolSyncMode;
  actionReason: SchoolActionReason;
  lastSuccessAt?: string;
  lastObservedAt?: string;
  recipe?: {
    version?: string;
    confidence?: number;
    state: SchoolRecipeState;
  };
  missingCapabilities?: SchoolActionCapability[];
  /** Collections where we saw some records but not proof we saw the last page. */
  incompleteCapabilities?: SchoolActionCapability[];
  /** Per-capability health, so one broken page does not condemn the rest.
   *  See lib/school/capabilityHealth.ts. */
  capabilities?: import("./capabilityHealth").CapabilityHealth[];
  /** Which stage of the capture→ACK chain is overdue, so the UI can say
   *  something more useful than "reconnect school". */
  chainState?: import("./chainTelemetry").ChainState;
};

export type SchoolCapabilities = Partial<Record<
  "courses" | "assignments" | "deadlines" | "messages" | "announcements" | "grades" | "submissions",
  boolean
>>;

export type SchoolSource = {
  sourceKey: SchoolSourceKey;
  vendorKey?: string;
  portalFingerprint: string;
  schoolLabel?: string;
  syncMode: SchoolSyncMode;
  capabilities: SchoolCapabilities;
};

export type SchoolConnection = SchoolSource & {
  connectedAt: string;
  lastObservedAt?: string;
};

export type SchoolRecord = {
  sourceRecordId: string;
  kind: DispatchRecordKind;
  title: string;
  subject?: string;
  detail?: string;
  url?: string;
  dueAt?: string;
  occurredAt?: string;
  status?: string;
  grade?: string;
};

export type SchoolPageRole =
  | "collection"
  | "detail"
  | "messages"
  | "grades"
  | "attachments"
  | "unknown";

export type SchoolLinkRelationship = "detail" | "attachment" | "unknown";

export type SchoolAcademicLink = {
  path: string;
  relationship: SchoolLinkRelationship;
  text?: string;
  downloadName?: string;
};

export type SchoolCaptureKind =
  | "hello"
  | "route"
  | "json-response-shape"
  | "dom-snapshot"
  | "navigation-edge"
  | "attachment-download";

export type SchoolDomCardEvidence = {
  captureId: string;
  selector: string;
  groupSelector: string;
  tag: string;
  text: string;
  title?: string;
  subject?: string;
  dueAt?: string;
  status?: string;
  grade?: string;
  teacher?: string;
  path?: string;
  sourceRecordId?: string;
  links?: SchoolAcademicLink[];
  classTokens?: string[];
  childTags?: string[];
  attributes?: Record<string, string>;
};

export type SchoolDomSnapshotPayload = {
  kind: "dom-snapshot";
  path: string;
  pageRole?: SchoolPageRole;
  rows: Array<Record<string, unknown>>;
  cards?: SchoolDomCardEvidence[];
  /**
   * Bounded/sanitized local HTML assembled only from academic candidate cards.
   * It exists so a local repair engine can compare structure after a portal UI
   * change. It is never uploaded by the watcher.
   */
  sanitizedHtml?: string;
  /** Set when the student explicitly chose Capture this page. */
  userAssisted?: boolean;
  /** Set after the student confirms the preview with Looks right. */
  captureConfirmed?: boolean;
};

export type SchoolNavigationEdgePayload = {
  kind: "navigation-edge";
  fromPath: string;
  toPath: string;
  relationship: SchoolLinkRelationship;
  sourceRecordId?: string;
  fromTitle?: string;
};

export type SchoolAttachmentDownloadPayload = {
  kind: "attachment-download";
  sourcePagePath?: string;
  sourceUrlPath?: string;
  localPath: string;
  fileName: string;
  mimeType?: string;
  sizeBytes?: number;
};

export type SchoolCaptureEvent = {
  type: "school.capture";
  sourceSessionId: string;
  sourceKey: SchoolSourceKey;
  origin: string;
  originFingerprint: string;
  observedAt: string;
  payload: {
    kind: SchoolCaptureKind;
    [key: string]: unknown;
  };
};

export type SchoolRecipe = {
  schemaVersion: 1;
  entity: DispatchRecordKind;
  source: {
    kind: "observed-json" | "observed-dom";
    endpointTemplate?: string;
    container?: string;
    selector?: string;
  };
  collectionPath?: string;
  fields: Record<string, string>;
};

export type SchoolRecipeValidation = {
  confidence: number;
  observations: number;
  activated: boolean;
  reasons: string[];
};
