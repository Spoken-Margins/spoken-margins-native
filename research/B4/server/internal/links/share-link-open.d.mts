// Types for share-link-open.mjs, so the web app (Web/src/packet/share-link.ts) type-checks against the same
// module the share page embeds (#3003). The module itself stays plain JavaScript for the Go server to embed.

export declare const PART: Readonly<{ preview: 1; packet: 2 }>;
export declare const DAMAGED_MESSAGE: string;
export declare class DamagedLinkError extends Error {}
export declare function keyFromFragment(hash: unknown): Uint8Array | null;
export declare function openPart(sealed: Uint8Array | ArrayBuffer, part: number, keyBytes: Uint8Array | null, subtle?: SubtleCrypto): Promise<Uint8Array>;
export declare function openPreview(sealed: Uint8Array | ArrayBuffer, hash: string, subtle?: SubtleCrypto): Promise<unknown>;
export declare const MAX_BEFORE_CHARACTERS: number;
export declare const MAX_AFTER_CHARACTERS: number;
export declare function checkPreview(preview: unknown): {
  source: { title: string; show: string; url: string };
  margins: { text: string; before: string; after: string }[];
};
export declare function safeSourceURL(raw: unknown): string;
