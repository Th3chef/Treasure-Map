# Changelog

## 1.3.0

- New option: **Loot Ledger**. The ledger beside the map is now its own option, so you can leave it off. With Mod Options Menu there's also a Loot Ledger on/off toggle in game (ESC > MODS > TREASURE MAP) that works right away.
- Updating from 1.2: tick **Loot Ledger** in your mod manager to keep the ledger.

## 1.2.1

- Lighter with the map open: about 0.06 ms a frame instead of about 0.24 ms in my test. The map no longer redraws for moves too small to see (it follows you a tiny bit every frame while you walk), the lists are read less often, and opening the map spreads its reads over a few frames.
- Supplies take fewer reads to place, and after a game update it checks the spots it knew before searching the game for them.
- Fixed a rare case where opening the map could leave the markers off until something on the map changed.

## 1.2.0

- New options: **Ammo Boxes**, **Grenade Packs** and **Stim Packs**. They're marked with the game's own icons (ammo in the game's ammo yellow, grenades in red, stims in blue) and a marker goes away when someone picks it up. They're drawn under the other markers so they never cover your loot or objectives.
- The loot ledger now goes from most to least important: objectives, then Super Credits down to Requisition Slips, then the supplies in their own group below a divider.
- Patch-proof: if a game update hides the supplies, only those three options turn off and the log says why.

## 1.1.1

- Fixed: objectives didn't show at all in some missions. On those missions the game keeps its objective list in a different order, and 1.1.0 took that for a broken list and switched the objectives off.
- An objective that doesn't look right is now skipped on its own, instead of switching all objectives off.
- Fixed: on a busy map with more than 128 samples and other loot listed, the loot markers could switch off.

## 1.1.0

- New option, **Objectives**: marks the side objectives you haven't discovered yet in bright cyan. With the Poor Intel modifier it also marks the real spot of each main objective the map only shows as an area, in the game's main objective orange. A marker goes away once the game shows that objective on its own map, or when it's done.
- Objective markers are a bit bigger than the loot markers.
- Loot ledger: objectives sit at the top, above a divider, with how many are still to be found.
- The markers and the ledger now draw on top of the Atmospheric Spores cloud.
- Patch-proof: if a game update hides the objectives or changes them, only the Objectives option turns off and the log says why; the loot markers keep working.

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
