package com.abracode.richtext

import java.net.URI

/**
 * When a document's REMOTE images (http / https) are fetched. Fetching is itself a disclosure: the request tells
 * the image's host that this document was rendered, from which address, and anything the URL carries - so Markdown
 * written by an untrusted party (a model, an agent, a web page) can use an image to send data wherever it likes the
 * moment it is shown. `data:` images carry their bytes inline and local `file:` images send nothing, so both are
 * always shown. An image already in the process-wide memory cache is shown in every mode, since showing cached bytes
 * sends nothing. A port of Swift's `RichTextRemoteImages`.
 */
enum class RichTextRemoteImages {
    /** Fetched as soon as the document renders: the default. */
    AUTOMATIC,
    /** A placeholder naming the image's host until the user taps it; then that one image is fetched. */
    ON_CLICK,
    /** Never fetched; the placeholder says so. */
    NEVER,
}

/** Why an image that is not loaded is not being fetched. A port of Swift's `RichTextImageHold`. */
internal enum class RichTextImageHold {
    /** Not held: loading, failed, or about to load. */
    NONE,
    /** A remote image under ON_CLICK: fetched when the user taps its placeholder. */
    AWAITING_CLICK,
    /** A remote image under NEVER. */
    OFF,
}

/** What an image's placeholder says, as on every renderer. A port of Swift's `RichTextImagePlaceholder`. */
internal object RichTextImagePlaceholder {
    /** The placeholder's text. [action] is the verb of the touch that loads a held image ("Tap"). */
    fun label(alt: String, url: String?, failed: Boolean, hold: RichTextImageHold, action: String): String {
        // The host as written, percent escapes kept: a decoded host could show an escaped "/" or line break and
        // pass one domain off as another.
        val host = url?.let { hostOf(it) } ?: "the web"
        return when (hold) {
            RichTextImageHold.AWAITING_CLICK -> "${alt.ifEmpty { "Image" }}\n$action to load from $host"
            RichTextImageHold.OFF -> "${alt.ifEmpty { "Image" }}\nNot loaded from $host: remote images are off"
            RichTextImageHold.NONE -> when {
                failed -> if (alt.isEmpty()) "image unavailable" else "$alt (unavailable)"
                else -> alt.ifEmpty { "loading image..." }
            }
        }
    }

    // java.net.URI keeps a host as written (it never decodes one); a host it cannot parse as a server name (an
    // underscore, an escape) comes from the authority, less its user information and port. The re-parse of
    // toASCIIString escapes a non-ASCII host as Swift's URL does, so a look-alike such as a Cyrillic "a" in
    // "apple.com" shows as its escapes instead of passing for the real domain.
    private fun hostOf(url: String): String? = try {
        val uri = URI(URI(url).toASCIIString())
        uri.host ?: uri.rawAuthority?.substringAfterLast('@')?.replace(Regex(":[0-9]*$"), "")
    } catch (e: Exception) {
        null
    }
}
