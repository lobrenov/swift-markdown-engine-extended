Uses: [Foo][ref], [Bar][], [ref], [Mixed Case][REF] and ![Pic][img].

Not defined: [nope][missing], [missing] and [x][ref][].

[ref]: Note.md
[bar]: <My Note.md#h> "Title"
[img]: pics/a%20b.png
[REF]: second.md
[unused]: unused.md
[web]: https://example.com/a.md
[hash]: #heading
[esc]: dir/x\.md?q=1

More: [web], [hash], [esc], [Foo [nested]][ref], [`code`][ref], `[ref]`, \[ref] and [ref](inline.md).

> Quote [q][quoted]
>
> [quoted]: quote.md

- Item [l][listed]
- [listed]: list.md

[multi]:
    multi.md
    "Title on its own line"

Text then
[late]: late.md

[late] [multi]

| Cell |
| --- |
| [Tab][ref] ![i][img] |

```
[ref]: code.md
[fenced]: fenced.md
```

[fenced] [first-wins]
