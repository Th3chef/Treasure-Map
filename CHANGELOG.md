# Changelog

## 1.0.2

- Safer across mission changes: the markers and the loot ledger check that the map's screen is still there right before every redraw, and let go of it (never touching it again) when a mission ends. A new mission is noticed even while the map is open.
- Fixed: when the game refused a replacement for a count number on a marker, the old one could be cleaned up twice.
- After a game update, the addresses it remembered are checked against the game's code before they are used; anything that changed means a fresh search (patch-proof).
- The start-up search reads the game's code in larger pieces.
- Log: clearer status lines, and read failures no longer cause extra log rewrites.
- The mod's icon and pictures show the loot ledger at the bottom left of the map, where 1.0.1 moved it.

## 1.0.1

- The loot ledger now sits at the bottom left of the map, so it's no longer cut off on 16:9 screens or by HUD elements at the screen's right edge. If there's no room left of the map, it goes to the right, and it always stays on screen.

## 1.0.0

- First release: map markers for Requisition Slips, Common, Rare and Super Samples, Medals and Super Credits, each kind its own option and color; same-kind pickups stacked on one spot share a marker with a count; a loot ledger at the bottom right of the map that counts down what's left. Opacity sliders with Mod Options Menu. Works without HD2 HUD+.
