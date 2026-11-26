# App Store – English (product page)

As of 26 Nov 2026: copyedited for native US English and checked against Apple's limits and
spellings; every claim re-checked against the code; then an independent second review by a US
copy editor was worked in. Replaces the version of 21 Nov.
Lines marked **[MAP]** only once the "Your World" map is in the submitted build; until then use
**[NO MAP]**. Same rules as the German page (`APP_STORE_DE.md`): Albumist works *for* the Photos
app, never against it; no absolute claims; "your photos" instead of "never a photo"; the developer
speaks as "I"; button names exactly as in the app.

Privacy wording (same as the German page): "Albumist never uploads your photos" and "all
analysis happens on your iPhone", never "everything stays on your iPhone" or "no photo ever leaves
your iPhone". Place-name lookups send coordinates to Apple by default (can be turned off), the map
loads map images from Apple, and with iCloud Photos the photos are in iCloud anyway.

Style: US English (organize, favorite, color), serial comma, curly quotes (“ ” ’), Apple's
spellings and capitalization (iPhone, iPad, Mac, iCloud Photos, Photos app, Lock Screen, Dark
Mode, Reduce Motion, Larger Text, Apple Intelligence, Apple Account). No plural product names
("iPhone models", not "iPhones") and never "IPHONE" in all caps (so no all-caps heading with it).

## Fields

**Name (max 30):** `Albumist – Photo Organizer` (26)
Alternative if search data after launch says "organizer" is too crowded: `Albumist – Trip Photo Albums` (28).

**Subtitle (max 30):** `Real albums for every trip` (26)

**Category:** Photo & Video (primary), Travel (secondary).

**Price:** €6.99 one-time (decided 25 Nov 2026); launch week €4.99 (decided 25 Nov 2026). Apple
converts the euro price for other storefronts; the price appears only in App Store Connect.

**Promotional text (max 170). No price** (the English text shows in dozens of currencies):
- Launch week: `Launch week special: unlock unlimited albums for less. Pay once, no subscription. Albumist finds your trips and turns them into real albums in your Photos app.` (159)
- After: `Years of photos, finally in order. Albumist finds your trips and turns them into real albums in your Photos app. Preview first, undo anytime. Analyzed on your iPhone.` (166)

The launch-week text says *what* is cheaper: the app is a free download anyway. Swap in "After"
on the last day of the launch price.

**Keywords (max 100 bytes, no spaces, nothing from name or subtitle):**
```
sort,vacation,holiday,travel,map,countries,places,screenshots,pictures,gallery,memories,folders,city
```
(100) No "clean"/"cleanup" (draws storage-cleaner searches the app does not serve), no "journal"
(misleading). U.K.: same list.

**Description** (max 4,000; this version 2,502 characters with the map, 2,407 without):

```
Thousands of photos and not a single album? Albumist finds your trips and turns them into real albums in your Photos app. You preview everything first, and Albumist never uploads your photos.

TRIPS BECOME ALBUMS
Albumist automatically finds your trips — from long vacations to day trips, even ones from years ago — and tells them apart from everyday life at home. Each trip gets its own album with a clear name, like “Lake Garda, August 2026,” right in Apple’s Photos app and, with iCloud Photos, on your Mac and iPad too.

PREVIEW FIRST, THEN CREATE
Albumist shows you every album and its photos up front. Remove photos, rename albums, and split or merge trips. Nothing changes until you tap “Create Albums Now.”

EVERYTHING CAN BE UNDONE
A list shows exactly what was created, and “Undo” puts everything back the way it was. Albumist never deletes or edits your photos. Already have albums that fit? Albumist adds to them instead of creating duplicates.

[MAP] YOUR WORLD
A globe showing everywhere you’ve taken photos. Replay a trip stop by stop with your best shots, and share your world as an image.
[NO MAP] YOUR TRAVEL ATLAS
A world map of every country you’ve taken photos in, with a flag and photo count for each. Ready to share as an image.

SEARCHES BECOME ALBUMS
Type “dogs Italy 2023” and Albumist shows you the matching photos. On iPhone models with Apple Intelligence, you can also search in natural language, like “barbecue at Grandma’s last summer.” Turn any search into an album.

MORE THAN TRIPS
Albumist also creates albums for:
• Countries, and cities if you like
• Places you visit often, with names you choose
• Screenshots, sorted by content: orders, tickets, recipes
• Documents like invoices and receipts
• Topics like dogs, beaches, or food
• Months and years, if you want them

PRIVATE BY DESIGN
• All analysis happens on your iPhone
• No account, no tracking, no ads
• For place names, iOS sends Apple’s map service only coordinates, never photos; you can turn this off
[MAP] • Map images come from Apple, only for the area you’re viewing; you can turn this off too

KEEPS WORKING IN THE BACKGROUND
Big libraries take time. You can leave Albumist while it works: as long as iOS allows, it keeps analyzing and shows its progress on your Lock Screen. Later, sort new photos with a single tap or with Siri.

PAY ONCE, NO SUBSCRIPTION
Your first 10 albums are free. After that, a one-time purchase unlocks as many albums as you like.

Albumist supports VoiceOver, Larger Text, Dark Mode, and Reduce Motion.

Albumist is made by an independent developer. Questions or ideas? Get in touch through the support page. I read every message.
```

What changed since 21 Nov (copyedit):
- Phrases that read as translated German were rewritten: "You see everything first", "day
  outings", "keeps them apart", "on its own", "Only for place names, iOS asks Apple, with the
  photo's location", "Then unlock Albumist once, no subscription", "Only when you tap … does
  anything change".
- "Take photos out, rename, split or merge trips" (verb without object) → parallel list.
- "SEARCH THE WAY YOU TALK" did not match the keyword example. Now both: keywords for everyone,
  natural language with Apple Intelligence (the app's own placeholder, `SearchView.swift`). The
  heading is now "SEARCHES BECOME ALBUMS": Photos can search on its own; the album made from the
  results is what Albumist adds.
- "keeps sorting" in the background suggested albums are created without consent; the app only
  analyzes in the background → "keeps analyzing". "add new photos" sounded like importing →
  "sort new photos" (matches the Siri phrase).
- Privacy: "no photo ever leaves your iPhone" → "Albumist never uploads your photos"; "iOS sends
  Apple only the location" → "only coordinates, never photos" (same as the privacy policy).
  "PRIVATE ON YOUR IPHONE" → "PRIVATE BY DESIGN"; "iPhones" → "iPhone models".
- Accessibility moved out of the privacy list into its own line.
- "Reach us … We read every message" → "Get in touch … I read every message", with a line before
  it that says who "I" is (one voice with the website and the press emails).
- Launch-week promo text says what is discounted; "Private on your iPhone" → "Analyzed on your
  iPhone". Keywords use the last 5 bytes (",city").
- Straight quotes → curly quotes; serial comma throughout; Apple's capitalization of Larger Text,
  Dark Mode, and Reduce Motion.

Same checks as the German page (Voice Control test, Family Sharing is off today, search examples
"dogs Italy 2023" and "barbecue at Grandma’s last summer" tried with the English demo library, the
second on an iPhone with Apple Intelligence; English date format of trip titles).

**What's New:** Not available for the first version ("This property isn’t available for the
first version of the app", App Store Connect Help, Platform version information). Template for
the first update, to be filled with real changes:
> New in this version: [one change people will notice]. Also: [improvement]. Thanks for all your
> messages. Keep them coming through the support page.

**In-app purchase** (`app.albumist.ios.unlock`):
- Display name (max 30): `Unlock Albumist` (15)
- Description (max 45): `Unlimited albums. Pay once, no subscription.` (44)

> Correction 26 Nov: the limits are 30 and 45 characters (App Store Connect Help, In-App Purchase
> information), not 35 and 55. The old description (51 characters) would have been rejected.

## Note on English locales

Enter the text as **English (U.S.)** and copy it to **English (U.K.)**. Some ASO guides say
Apple's German storefront also reads U.K. English keywords; Apple does not say so. Do not bend the
U.K. field for it; check App Analytics after launch.
