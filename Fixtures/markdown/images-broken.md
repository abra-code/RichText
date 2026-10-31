Every image in this document fails on purpose, to show the fallbacks: example.test never resolves, the data: image holds only a PNG signature, and the local file does not exist.

A block image on its own line:

![a remote diagram](https://example.test/diagram.png)

An inline ![small icon](https://example.test/icon.png) inside a sentence.

An image with an empty alt: ![](https://example.test/nameless.png)

A data-URI image ![pixel](data:image/png;base64,iVBORw0KGgo=) inline.

A missing local image ![local](file:///nonexistent/missing.png) falls back to alt text.
