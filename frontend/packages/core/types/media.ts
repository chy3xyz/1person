// Media-asset types used by the file-upload pipeline and the attachment
// preview layer. These shapes are consumed by the workspace media library
// and the chat attachment uploader.

export type MediaAssetKind = "image" | "video" | "document" | "archive" | "other";

export interface MediaAsset {
  id: string;
  workspaceId: string;
  /** Uploader user id. */
  uploaderId: string;
  /** Original filename as provided by the uploader. */
  originalName: string;
  /** MIME type detected during upload. */
  mimeType: string;
  /** Size in bytes. */
  sizeBytes: number;
  kind: MediaAssetKind;
  /** Public or signed download URL. */
  url: string;
  /** Optional thumbnail URL for image/video assets. */
  thumbnailUrl?: string;
  /** Width in pixels (images/video only). */
  width?: number;
  /** Height in pixels (images/video only). */
  height?: number;
  createdAt: string;
}

export interface UploadRequest {
  /** Presigned POST URL returned by the server. */
  uploadUrl: string;
  /** Form fields that must accompany the upload POST body. */
  fields: Record<string, string>;
  /** Asset ID assigned by the server before upload completes. */
  assetId: string;
  /** Token that expires after this ISO-8601 timestamp. */
  expiresAt: string;
}
