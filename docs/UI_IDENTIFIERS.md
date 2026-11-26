# Fixed identifiers for UI tests

Rebuild stage 2 (owner's decision 26.11.2026, "alles wie empfohlen"). Each strand converts
its own UI tests, file by file, when it touches them anyway. Nobody runs a conversion PR just for
this.

## Why

Many UI tests find elements by the words on screen, for example `app.buttons["Weiter"]`,
`navigationBars["Vorschau"]` or `label CONTAINS 'von'`. On 26.11.2026 there were about 320 such
lookups. They break, although the app is right, in these cases:

- the wording changes (the editing of 26.11. alone changes several texts);
- the app runs in English;
- the text size is larger, and a label is shortened or wraps;
- a second element shows the same words (a "Fertig" in the sheet and one in the bar).

Each such red costs a Mac run of about 25 minutes and a restart. A fixed identifier stays the
same through all of these.

## The rule

1. **Name.** Use `screen.element`, or `screen.element.part` where needed. Each part is lower
   camel case, for example `plan.apply`, `viewer.position`, `analysis.details.summary` or
   `home.since.confirm`. The screen comes first, so a search for `viewer.` finds everything of the
   viewer.
2. **Set it in the app** where the element is made, as `.accessibilityIdentifier("plan.apply")`.
   An identifier never shows on screen and VoiceOver never reads it. The label stays as it is.
   The rows of one list share one identifier (`history.row`); the test picks the row by its
   index or by a value it reads.
3. **Look it up in the test** with the helpers in `App/AlbumistUITests/UIID.swift`:
   - `app.element(id: "viewer.position")` returns the first element of any kind. It does not wait.
   - `app.elements(id: "history.row")` returns every element with that identifier.
   - `app.waitFor(id: "plan.apply", timeout: 20)` waits. When the element does not come, it prints
     `UI_STEP_MISSING` and the test fails; it never passes silently.
   - `app.tap(id: "plan.apply", timeout: 20)` waits, then taps.

   "Any kind" means a test keeps working when a text becomes a button.
4. **Check the words only on purpose.** A test whose point is the wording may keep looking up
   by words. Examples are the promise texts, the English texts and an iOS alert that has no
   identifier of ours. Such a lookup carries `// text: <why>` on its line.
5. **Assert values by identifier, not by searching text.** For example, read
   `app.element(id: "viewer.position").label == "1 von 3.348"` instead of searching for a text
   that contains "von".

## What checks it (Linux, seconds, no Mac minutes)

`.github/scripts/tests/test_ui_identifiers.py` (`UIIdentifierRuleTests`) runs three checks:

- Every identifier a UI test asks for (`["x.y"]`, `matching(identifier: "x.y")`,
  `element/elements/waitFor/tap(id: "x.y")`) is set somewhere in the app. A renamed or mistyped
  identifier is red on Linux, not after 25 minutes on a Mac.
- Every identifier the app sets follows the pattern above.
- Lookups by visible words only go down, per file (`CEILING`). A new lookup by words needs a fixed
  identifier instead, or `// text:`. When you convert a file, lower its number in `CEILING`.

## How to convert a test (per strand)

1. Pick the lookups by words in the test you are changing anyway.
2. Give each element an identifier in the app (rule 1 and 2). One commit can cover the app and
   the test.
3. Replace each lookup with `app.element(id:)`, `app.waitFor(id:)` or `app.tap(id:)`. Keep the
   timeouts the test had.
4. Run `python3 -m unittest discover -s .github/scripts/tests` and lower `CEILING` for the file.
5. The UI run of the pull request then shows that the test still finds everything (smoke test
   on the draft, the full run on "Ready for review").
