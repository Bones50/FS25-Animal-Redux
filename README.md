# Animal Redux (FS25)

An extension to [Distribution Redux](https://github.com/Bones50/FS25-Distribution-Redux)
that deepens Farming Simulator 25's animal husbandry.

**Animal Redux requires Distribution Redux.** It declares a hard dependency and
disables itself with a log message if Distribution Redux is not installed.

## Status

Early scaffold. This build establishes the link to Distribution Redux and does
nothing else yet.

## Planned scope

1. **Extended husbandries** — new feed types and new output types.
2. **Smarter pooled feed** — demand shaped toward the game's optimal feed mix,
   with more granular per-feed control.
3. **Animal trading** — configurable buying and selling of animals.

## Building

The mod is packed by `deploy-animal.ps1`, which sits beside `deploy-dr.ps1`
outside this repository. It validates every Lua file with `luac -p` first, then
writes `FS25_Animal_Redux.zip` into the FS25 mods folder.

Use `deploy-all.ps1` to deploy Animal Redux and Distribution Redux together —
they are a dependency pair and should be tested as one.

Close the game before deploying, or the write is silently skipped.

## Contributing translations

Copy `translations/translation_en.xml` to `translation_<code>.xml` and translate
the `text` attributes. Any key you leave out falls back to English, so partial
translations are welcome.

An XML comment must not contain a double hyphen — it is a parse error and the
file will not load.
