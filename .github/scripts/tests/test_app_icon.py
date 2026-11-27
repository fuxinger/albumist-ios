"""The app icon in the layered format of iOS 26 (DS-20): App/Albumist/Resources/AppIcon.icon, the
Icon Composer document built from the layers of the chosen design "Glass Stack" (14.11.2026,
design/icon/README.md). Checks here what otherwise needs a Mac: the document parses, holds the
design's layers in their order and with their colours, glass only on the front card, every image it
names is there (and nothing else), the layers use only SVG that Icon Composer reads, and the project
hands it to Xcode as the one app icon. What only a Mac can confirm (actool takes it, the Home Screen
in light, dark and tinted) is listed in the handoff of DS-20.

The format (Xcode 26 and later): a folder with `icon.json` and `Assets/`. `groups` and their
`layers` are listed front to back, as Icon Composer's sidebar shows them; colours are written as
"srgb:r,g,b,a" with five decimals; `*-specializations` hold a value per appearance ("dark",
"tinted"). Read from Apple's "Creating your app icon using Icon Composer" and from documents
Icon Composer wrote in public projects.
"""
import json
import math
import os
import pathlib
import re
import unittest
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = pathlib.Path(HERE).parents[2]
ICON = REPO / "App" / "Albumist" / "Resources" / "AppIcon.icon"
DESIGN = REPO / "design" / "icon"
PROJECT = REPO / "App" / "project.yml"
TOOLCHAIN = REPO / ".github" / "toolchain.json"

# The design's layers from back to front (design/icon/README.md: "in dieser Reihenfolge"). Its
# background (0-background.svg) is the document's fill: Icon Composer draws backgrounds itself and
# turns them dark and tinted, a background layer would stay light (Apple: "Remove background
# colors and gradients" before export; HIG: "Icon Composer supports solid colors and gradients for
# background layers").
LAYERS = ["1-back-card", "2-middle-card", "3-front-card", "4-sun", "5-hills"]
# "die vordere aus Milchglas": the front card is frosted glass, the rest is flat.
GLASS = {"3-front-card"}
# Icon Composer's limit ("a maximum of four groups").
MAX_GROUPS = 4
DOCUMENT_KEYS = {"fill", "fill-specializations", "groups", "supported-platforms", "color-space-for-untagged-svg-colors"}
GROUP_KEYS = {"name", "layers", "hidden", "shadow", "translucency", "blur-material", "lighting", "specular",
              "opacity", "blend-mode", "position"}
LAYER_KEYS = {"name", "image-name", "glass", "hidden", "fill", "opacity", "blend-mode", "position"}
APPEARANCES = {"dark", "tinted"}
COLOUR = re.compile(r"(?:srgb|extended-srgb|display-p3):(?:\d\.\d{5},){3}\d\.\d{5}|(?:gray|extended-gray):\d\.\d{5},\d\.\d{5}")
# The first XcodeGen that adds a `.icon` folder as one resource ("Added built in `.icon` folder
# support for IconComposer #1600", 2.45.1). Before, it listed icon.json and the SVGs one by one
# and Xcode did not see an icon (XcodeGen issue #1556).
XCODEGEN_ICON_SUPPORT = (2, 45, 1)


def load():
    return json.loads((ICON / "icon.json").read_text(encoding="utf-8"))


def back_to_front(document):
    """(group, layer) for every layer of the document, from the back to the front."""
    return [(group, layer) for group in reversed(document["groups"]) for layer in reversed(group["layers"])]


def srgb(hex_colour: str) -> str:
    """"#DCEDEF" as Icon Composer writes it."""
    channels = [int(hex_colour[index:index + 2], 16) / 255 for index in (1, 3, 5)]
    return "srgb:" + ",".join(f"{value:.5f}" for value in channels + [1.0])


def specialized(owner: dict, key: str) -> dict:
    """The appearance ("" for the default) → value of `key` of a document, group or layer."""
    values = {"": owner[key]} if key in owner else {}
    for entry in owner.get(f"{key}-specializations", []):
        values[entry.get("appearance", "")] = entry["value"]
    return values


def theme(name: str, key: str) -> str:
    """A colour of the finished icon for `name` (light, dark, tinted) as make_icon.py draws it."""
    text = (DESIGN / "make_icon.py").read_text(encoding="utf-8")
    start = text.index(f'"{name}":')
    found = re.search(rf'\b{key}="(#[0-9A-Fa-f]{{6}})"', text[start:])
    return found.group(1).upper()


def target_block(name: str) -> str:
    """The lines of target `name` in project.yml (read as text, like the other checks here)."""
    lines = PROJECT.read_text(encoding="utf-8").splitlines()
    start = lines.index(f"  {name}:")
    end = next((index for index in range(start + 1, len(lines)) if re.match(r"  \S", lines[index])), len(lines))
    return "\n".join(lines[start:end])


class IconDocumentTests(unittest.TestCase):
    def test_the_document_parses_and_holds_only_what_icon_composer_writes(self):
        document = load()
        self.assertLessEqual(set(document), DOCUMENT_KEYS)
        self.assertTrue(document["groups"])
        for group in document["groups"]:
            self.assertLessEqual({key.removesuffix("-specializations") for key in group}, GROUP_KEYS, group.get("name"))
            self.assertTrue(group["layers"])
            for layer in group["layers"]:
                self.assertLessEqual({key.removesuffix("-specializations") for key in layer}, LAYER_KEYS, layer.get("name"))

    def test_the_layers_are_the_designs_in_its_order(self):
        layers = [layer["name"] for _, layer in back_to_front(load())]
        self.assertEqual(layers, LAYERS)
        for _, layer in back_to_front(load()):
            self.assertEqual(layer["image-name"], layer["name"] + ".svg")

    def test_at_most_four_groups(self):
        self.assertLessEqual(len(load()["groups"]), MAX_GROUPS)

    def test_every_image_is_the_designs_layer_and_nothing_else_is_there(self):
        named = {layer["image-name"] for _, layer in back_to_front(load())}
        present = {path.name for path in (ICON / "Assets").iterdir()}
        self.assertEqual(present, named)
        for name in named:
            with self.subTest(image=name):
                self.assertEqual((ICON / "Assets" / name).read_bytes(), (DESIGN / name).read_bytes(),
                                 "the icon's layer differs from design/icon: copy it again from there")
        self.assertEqual({path.name for path in ICON.iterdir()}, {"icon.json", "Assets"})

    def test_glass_only_on_the_front_card(self):
        for group, layer in back_to_front(load()):
            with self.subTest(layer=layer["name"]):
                self.assertIn("glass", layer, "Icon Composer gives every layer glass unless it says otherwise")
                self.assertIs(layer["glass"], layer["name"] in GLASS)
                self.assertNotIn("glass-specializations", layer)
        front = next(group for group, layer in back_to_front(load()) if layer["name"] in GLASS)
        self.assertEqual(len(front["layers"]), 1, "the frosted glass is the card's own group")
        self.assertTrue(front["translucency"]["enabled"], "frosted glass lets the cards behind show through")
        self.assertGreater(front.get("blur-material") or 0, 0, "frosted glass blurs what is behind it")

    def test_the_landscape_lies_flat_on_the_front_card(self):
        document = load()
        landscape = next(group for group in document["groups"]
                         if {layer["name"] for layer in group["layers"]} == {"4-sun", "5-hills"})
        self.assertEqual(landscape["shadow"]["kind"], "none")
        self.assertFalse(landscape["translucency"]["enabled"])
        for name in ("1-back-card", "2-middle-card", "3-front-card"):
            card = next(group for group in document["groups"] if group["layers"][0]["name"] == name)
            with self.subTest(card=name):
                self.assertNotEqual(card["shadow"]["kind"], "none", "the cards lie on each other")

    def test_the_background_is_the_designs_gradient_from_top_to_bottom(self):
        stops = re.findall(r'stop-color="(#[0-9A-Fa-f]{6})"', (DESIGN / "0-background.svg").read_text(encoding="utf-8"))
        self.assertEqual(len(stops), 2)
        fill = specialized(load(), "fill")[""]
        self.assertEqual(fill["linear-gradient"], [srgb(stop.upper()) for stop in stops])
        self.assertEqual(fill["orientation"], {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}})
        self.assertNotIn("0-background", [layer["name"] for _, layer in back_to_front(load())])

    def test_dark_and_tinted_are_the_systems_except_the_hills_in_dark(self):
        document = load()
        # The dark background is the one iOS draws for dark icons (the finished dark icon of
        # 14.11. imitates it); the tinted look is iOS's own.
        self.assertEqual(specialized(document, "fill"), {"": specialized(document, "fill")[""], "dark": "system-dark"})
        # The one colour the finished dark icon changes in kind: the hills turn light, or they
        # vanish on the darker glass.
        specializations = {}
        for group, layer in back_to_front(document):
            for owner, label in ((group, group.get("name")), (layer, layer["name"])):
                for key in owner:
                    if key.endswith("-specializations"):
                        specializations.setdefault((label, key), owner[key])
        self.assertEqual(specializations, {
            ("5-hills", "fill-specializations"): [{"appearance": "dark", "value": {"solid": srgb(theme("dark", "hills"))}}],
        })

    def test_colours_and_appearances_are_written_as_icon_composer_writes_them(self):
        text = (ICON / "icon.json").read_text(encoding="utf-8")
        for colour in re.findall(r'"((?:srgb|extended-srgb|display-p3|gray|extended-gray):[^"]*)"', text):
            with self.subTest(colour=colour):
                self.assertRegex(colour, rf"^(?:{COLOUR.pattern})$")
        for appearance in re.findall(r'"appearance" : "([^"]*)"', text):
            self.assertIn(appearance, APPEARANCES)
        # Xcode's JSON layout, so a save from Icon Composer changes only what changed.
        self.assertEqual(text, json.dumps(load(), indent=2, separators=(",", " : "), sort_keys=True) + "\n")

    def test_for_iphone_only(self):
        # The app runs on iPhone only (project.yml: TARGETED_DEVICE_FAMILY 1); "squares" are iOS
        # and macOS, "circles" watchOS.
        self.assertEqual(load()["supported-platforms"], {"squares": ["iOS"]})


class LayerTests(unittest.TestCase):
    """The SVG layers use only what Icon Composer reads well (Apple: export SVG, PNG for
    "layers that contain unsupported SVG features"; no blur, shadow, opacity: the system adds them)."""

    SHAPES = {"path": {"d", "fill"}, "circle": {"cx", "cy", "r", "fill"}}

    def test_every_layer_is_a_plain_shape_on_the_full_canvas(self):
        for name in LAYERS:
            with self.subTest(layer=name):
                root = ET.fromstring((ICON / "Assets" / f"{name}.svg").read_text(encoding="utf-8"))
                self.assertEqual(root.tag, "{http://www.w3.org/2000/svg}svg")
                self.assertEqual((root.get("viewBox"), root.get("width"), root.get("height")), ("0 0 1024 1024", "1024", "1024"))
                children = list(root)
                self.assertEqual(len(children), 1, "one shape per layer")
                shape = children[0]
                tag = shape.tag.split("}")[1]
                self.assertIn(tag, self.SHAPES, "only paths and circles: no filter, mask, clip, text, image or style")
                self.assertEqual(set(shape.attrib), self.SHAPES[tag], "a solid fill, no opacity, stroke or transform")
                self.assertRegex(shape.get("fill"), r"^#[0-9A-F]{6}$")
                self.assertEqual(list(shape), [])

    def test_the_paths_use_plain_commands(self):
        for name in LAYERS:
            path = re.search(r' d="([^"]*)"', (ICON / "Assets" / f"{name}.svg").read_text(encoding="utf-8"))
            if path:
                with self.subTest(layer=name):
                    self.assertRegex(path.group(1), r"^[MLHVAZ0-9 .\-]+$")

    def test_the_hills_end_at_the_front_cards_round_corners(self):
        """The landscape lies on the front card and ends where the card does: the hills reached
        about 12 px past its bottom right corner and 4 px past the left one, also in the App
        Store's large icon (design wave 3, owner's list point 26). Every point of the hills lies on
        the card or its edge, so the straight lines between them do too (the card is convex), and
        each arc of the hills is the card's own corner: its radius, both ends on the card's edge."""
        corners = points(layer_path("3-front-card"))
        left, right = min(x for x, _, _ in corners), max(x for x, _, _ in corners)
        top, bottom = min(y for _, y, _ in corners), max(y for _, y, _ in corners)
        arcs = {arc for _, _, arc in corners if arc}
        self.assertEqual(len(arcs), 1, "the card has one corner radius")
        (rx, ry), = arcs
        self.assertEqual(rx, ry)
        radius = rx

        def beyond(x, y):
            """How far (x, y) lies past the card's rounded edge (zero or less: on the card)."""
            centre = (min(max(x, left + radius), right - radius), min(max(y, top + radius), bottom - radius))
            return math.dist((x, y), centre) - radius

        hills = points(layer_path("5-hills"))
        for index, (x, y, arc) in enumerate(hills):
            with self.subTest(point=(x, y)):
                self.assertLessEqual(beyond(x, y), 0.05, "a point of the hills lies past the front card's edge")
                if arc:
                    self.assertEqual(arc, (radius, radius), "an arc of the hills is not the card's corner")
                    start = hills[index - 1]
                    for end in ((start[0], start[1]), (x, y)):
                        self.assertAlmostEqual(beyond(*end), 0, delta=0.05, msg="an arc of the hills leaves the card's edge")


def layer_path(name: str) -> str:
    """The `d` of a layer's one path, as the icon's document holds it."""
    return re.search(r' d="([^"]*)"', (ICON / "Assets" / f"{name}.svg").read_text(encoding="utf-8")).group(1)


def points(d: str) -> list:
    """The points a path of absolute M, L, H, V, A and Z commands goes to, each with its arc's
    radii (rx, ry), or None for a straight line."""
    tokens = re.findall(r"[MLHVAZ]|-?\d+(?:\.\d+)?", d)
    found, x, y, index = [], 0.0, 0.0, 0
    while index < len(tokens):
        command = tokens[index]
        index += 1
        if command in ("M", "L"):
            x, y = float(tokens[index]), float(tokens[index + 1])
            index += 2
            found.append((x, y, None))
        elif command == "H":
            x = float(tokens[index])
            index += 1
            found.append((x, y, None))
        elif command == "V":
            y = float(tokens[index])
            index += 1
            found.append((x, y, None))
        elif command == "A":
            arc = (float(tokens[index]), float(tokens[index + 1]))
            x, y = float(tokens[index + 5]), float(tokens[index + 6])
            index += 7
            found.append((x, y, arc))
        elif command != "Z":
            raise ValueError(f"unexpected {command!r} in {d!r}")
    return found


class ProjectTests(unittest.TestCase):
    def test_the_project_names_it_as_the_app_icon(self):
        block = target_block("Albumist")
        found = re.search(r"^\s+ASSETCATALOG_COMPILER_APPICON_NAME:\s*(\S+)\s*$", block, re.MULTILINE)
        self.assertEqual(found.group(1), ICON.stem, "the App Icon setting names the .icon without its extension")

    def test_the_target_takes_it_from_its_sources(self):
        block = target_block("Albumist")
        sources = re.findall(r"^\s+- path:\s*(\S+)\s*$", block.split("dependencies:")[0], re.MULTILINE)
        relative = ICON.relative_to(PROJECT.parent).as_posix()
        self.assertTrue(any(relative == source or relative.startswith(source.rstrip("/") + "/") for source in sources),
                        f"{relative} is in none of the target's sources {sources}")
        self.assertNotIn("excludes", block.split("dependencies:")[0])

    def test_the_pinned_xcodegen_adds_it_as_one_resource(self):
        version = json.loads(TOOLCHAIN.read_text(encoding="utf-8"))["xcodegen"]["version"]
        self.assertGreaterEqual(tuple(int(part) for part in version.split(".")), XCODEGEN_ICON_SUPPORT)

    def test_ios_26_needs_no_older_icon(self):
        # Xcode makes images for older systems from the .icon itself; with iOS 26 as the oldest
        # there are none, so the asset catalog keeps no second "AppIcon".
        found = re.search(r'deploymentTarget:\s*\n\s+iOS:\s*"(\d+)\.\d+"', PROJECT.read_text(encoding="utf-8"))
        self.assertGreaterEqual(int(found.group(1)), 26)

    def test_one_source_named_app_icon(self):
        app = REPO / "App" / "Albumist"
        sets = sorted(path.relative_to(REPO).as_posix() for path in app.rglob("*.appiconset"))
        self.assertEqual(sets, [], "Xcode takes the .icon over an AppIcon set of the same name: one source only")
        self.assertEqual(sorted(path.relative_to(REPO).as_posix() for path in app.rglob("*.icon")),
                         [ICON.relative_to(REPO).as_posix()])


if __name__ == "__main__":
    unittest.main()
