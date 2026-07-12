A bare URL https://swift.org gets linked.

An http URL http://example.test/path?q=1 gets linked.

A www prefix www.example.test becomes an http link.

Trailing sentence punctuation is trimmed: see https://swift.org, and https://example.test/page.

A URL in parentheses (https://swift.org) keeps balanced brackets.

A URL inside `code https://swift.org` is not autolinked.

A URL inside an existing [https://swift.org](https://example.test) link is not re-linked.
