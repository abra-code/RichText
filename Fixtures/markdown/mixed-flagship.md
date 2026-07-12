# RichText Feature Tour

A flagship document that exercises **strong**, *emphasis*, ***both***, ~~strikethrough~~,
`inline code`, a [link](https://swift.org), and an autolinked https://example.test all together.

## Code

```swift
func greet(_ name: String) -> String {
    return "Hello, \(name)!"  // interpolation
}
```

## A quote with structure

> Design goal: render a whole document as one selectable unit.
> > Even nested quotes keep their bar.

## Lists

1. Parse the markdown
2. Build the model
   - totality is sacred
   - bounds are preserved
3. Render per block

## A table

| Block | Renders as |
| :-- | :-: |
| heading | sized text |
| code | a card |
| table | a grid |

---

An image below:

![abracadabra](https://abracode.com/ActionUI/abracadabra.png)

A closing paragraph with a hard break here\
and a final line.
