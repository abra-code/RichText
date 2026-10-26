A bare URL https://swift.org gets linked.

An http URL http://example.test/path?q=1 gets linked.

A www prefix www.example.test becomes an http link.

Trailing sentence punctuation is trimmed: see https://swift.org, and https://example.test/page.

A URL in parentheses (https://swift.org) keeps balanced brackets.

A URL inside `code https://swift.org` is not autolinked.

A URL inside an existing [https://swift.org](https://example.test) link is not re-linked.

A bare domain example.test stays text, as does WWW.EXAMPLE.TEST in upper case.

An email someone@example.test gets mailto:, while mailto:someone@example.test and ftp://files.example.test/a.txt link as written.

A host with an underscore in its last labels, www.ex_ample.test, is not linked.

An unbalanced bracket (see https://example.test/wiki/Foo_(bar))) keeps only the balanced pair.

A URL in angle brackets <https://swift.org> and one in bold **https://swift.org/** link once.
