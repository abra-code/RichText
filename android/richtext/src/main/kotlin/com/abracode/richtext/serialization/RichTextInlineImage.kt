package com.abracode.richtext.serialization

// The (original) bytes + format of a loaded image, used to embed it into copied HTML so the picture survives
// paste into other rich editors (a loaded image only - unloaded ones fall back to the URL / alt text). Ported
// from Sources/RichText/Rendering/RichTextImage.swift, trimmed to what the serializer needs; the on-screen
// display size lives in the Compose renderer (Stage D), not here.

/** The image container format. GIF is kept verbatim so animation survives to HTML targets. */
enum class RichTextImageFormat(val mimeType: String) {
    PNG("image/png"),
    JPEG("image/jpeg"),
    GIF("image/gif"),
}

/** Encoded bytes + format of a loaded image, for embedding as a `data:` URI in copied HTML. */
class RichTextInlineImage(
    val data: ByteArray,
    val format: RichTextImageFormat,
)

/**
 * Resolves an image URL to its loaded bytes, for embedding in copied HTML. Returns null for images that are not
 * loaded (they fall back to the URL / alt text). The serializer defaults to a resolver that returns null for
 * everything, so callers that do not care about embedded images are unaffected.
 */
typealias RichTextImageResolver = (String) -> RichTextInlineImage?
