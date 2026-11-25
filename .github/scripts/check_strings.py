"""Fails when a UI string in the app is missing from Localizable.xcstrings, has no
English translation, or breaks an English wording rule (english_rule.py: "Certain", not "Safe";
American spelling; buttons in title case), or when a test of the app target (App/AlbumistTests)
looks up a text by a key the catalog no longer has (second review of P3-09: three Mac tests
still built their expected text from the removed keys "von %lld Fotos", "%lld Orte" and
"%lld Fotos von zu Hause"). Usage: python3 check_strings.py <repo root>"""
import json, os, re, sys, glob
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import english_rule

CATALOG = 'App/Albumist/Resources/Localizable.xcstrings'
pat = re.compile(r'(?:(?:Text|Button|Label|Section|navigationTitle|Toggle|TextField|NavigationLink|ContentUnavailableView|Picker|confirmationDialog|LabeledContent|LocalizedStringKey|accessibilityLabel|Link|Tab|alert|IntentDescription)\(|String\(localized: |LocalizedStringResource = |TypeDisplayRepresentation \{ |dialog: |shortTitle: |@Parameter\(title: )\s*"((?:[^"\\]|\\.)*)"')
# In the tests only what they look up in the catalog: `String(localized: "…")`, a `Text("…")`
# (not `recognizedText("…")` or other test data) and `localizedString(forKey: "…")`.
test_pat = re.compile(r'(?:String\(localized: |(?<![A-Za-z_.])Text\()\s*"((?:[^"\\]|\\.)*)"')
test_key_pat = re.compile(r'localizedString\(forKey: "((?:[^"\\]|\\.)*)"')
# A multi-line literal (`"""` on lines of their own), for a text too long for one line of code.
MULTI_LINE = re.compile(r'"""[ \t]*\n(.*?)\n([ \t]*)"""', re.S)
INTERPOLATION = re.compile(r'\\\((?:[^()]|\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\))*\)')


def one_line(src):
    """The source with each multi-line literal written as the one-line literal of the same text.

    Its lines lose the indentation of the closing quotes; a line ending in a backslash goes on
    without a line break (the way a long text is wrapped), any other line ends in `\\n`. The
    newlines it took follow the literal, so the lines after it keep their numbers."""
    def joined(m):
        indent, lines, text = m.group(2), m.group(1).split('\n'), ''
        for number, line in enumerate(lines, 1):
            line = line[len(indent):] if line.startswith(indent) else line.lstrip()
            if (len(line) - len(line.rstrip('\\'))) % 2:
                text += line[:-1]
            else:
                text += line + ('\\n' if number < len(lines) else '')
        return '"' + re.sub(r'(?<!\\)"', '\\"', text) + '"' + '\n' * m.group(0).count('\n')
    return MULTI_LINE.sub(joined, src)


def norm(k):
    k = k.replace('%%', '%')
    k = re.sub(r'%(lld|ld|d|@|f|\.\d+f)', '#', k)
    return k


def load(root):
    return json.load(open(f'{root}/{CATALOG}'))


def key_of(literal):
    """The catalog key a Swift literal stands for, every interpolation as `#`."""
    return INTERPOLATION.sub('#', literal).replace('\\"', '"')


def missing_in_app(root, keys):
    missing = {}
    for f in glob.glob(f'{root}/App/Albumist/**/*.swift', recursive=True):
        src = one_line(open(f).read())
        for m in pat.finditer(src):
            lit = m.group(1)
            if not re.search(r'[A-Za-zÄÖÜäöü]', lit): continue
            k = key_of(lit)
            if norm(k) not in keys:
                missing.setdefault(k, f.split('/')[-1])
    return missing


def missing_in_tests(root, catalog_keys):
    """Keys the app's unit tests look up that are not in the catalog, as (file:line, key).

    A missing key does not fail the lookup: iOS shows the key itself, so the test compares the
    app's text with a German key and fails on the Mac, or (in English) passes for the wrong
    reason."""
    keys = {norm(k) for k in catalog_keys}
    found = []
    for f in sorted(glob.glob(f'{root}/App/AlbumistTests/**/*.swift', recursive=True)):
        src = one_line(open(f).read())
        def where(m):
            return f'{os.path.relpath(f, root)}:{src.count(chr(10), 0, m.start()) + 1}'
        for m in test_pat.finditer(src):
            k = key_of(m.group(1))
            if not re.search(r'[A-Za-zÄÖÜäöü]', k): continue
            if norm(k) not in keys:
                found.append((where(m), k))
        for m in test_key_pat.finditer(src):
            k = m.group(1).replace('\\"', '"')
            # Dotted names are UserDefaults keys, not texts.
            if re.fullmatch(r'[\w.]+', k) and '.' in k: continue
            if k not in catalog_keys:
                found.append((where(m), k))
    return found


def main(root):
    cat = load(root)
    keys = {norm(k): k for k in cat['strings']}
    missing = missing_in_app(root, keys)
    for k, f in sorted(missing.items(), key=lambda x: x[1]):
        print(f'MISSING_STRING {f} | {k}')
    in_tests = missing_in_tests(root, set(cat['strings']))
    for place, k in in_tests:
        print(f'MISSING_TEST_STRING {place} | {k}')
    # Every catalog entry needs English; German plural forms are optional.
    untranslated = [k for k, v in cat['strings'].items()
                    if v.get('shouldTranslate', True) and 'en' not in v.get('localizations', {})]
    for k in untranslated:
        print(f'NO_ENGLISH | {k}')
    style = english_rule.offenders(root)
    for k, v, problem in style:
        print(f'ENGLISH_STYLE | {k} | {v} | {problem}')
    print(f'STRINGS_CHECKED {len(cat["strings"])} catalog entries, {len(missing)} missing, '
          f'{len(in_tests)} missing in tests, {len(untranslated)} without English, {len(style)} English style problems')
    return 1 if missing or in_tests or untranslated or style else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
