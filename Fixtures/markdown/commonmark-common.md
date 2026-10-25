Identifiers like snake_case_word stay literal, and so does 2 * 3 * 4.

Intraword stars still emphasize: a*b*c, and _underscores_ work between spaces.

Unclosed markers stay literal: **unclosed bold and *italic.

Autolinks in angle brackets: <https://example.com/path> and <someone@example.com>.

Entities decode: AT&amp;T, &copy; 2026, &#169; and &#x2014; but &unknown; stays.

A link with a title [Swift](https://swift.org "The Swift site") and one with spaces [doc](<https://example.com/a b>).

An empty destination [shows only its text]() here.

A URL with underscores https://example.com/some_path_here stays one link.

An unclosed *star leaves later *emphasis* alone, as in f(*args) for *each* item.

Link text keeps its spans: [*star](https://example.com) and *after*.

Entity digits are ASCII only: &#+12; and &#٣; stay.
