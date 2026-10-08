# Treasure Map - source

A Bingus Shared Loader Lua mod. The core addon (`lua/`) does all the work; each option addon only sets a flag the core reads.

    lua/head.lua, lua/scan.lua, lua/body.lua
                    the core addon, joined in this order by build.py (head: memory reads and the log;
                    scan: finding the game's addresses in its code; body: the lists, positions, map view and drawing)
    build.py        builds the mod zip (Python 3 + Pillow):
                      python3 build.py out              -> out/Treasure-Map-<ver>.zip (the release)
                      python3 build.py out --tester     -> the Tester build (extra details in the log)
                      python3 build.py out --test N     -> numbered test build N (logs to Logs\test)
    icons.py        the marker icons (vector copies of the game's pickup icons), rendered into 32x32 textures
    art.py          the Arsenal option pictures
    patch_writer.py writes the patch archives
    README.txt      the readme inside the mod zip
    artwork/        hero.py + cards.py: the thumbnail, gallery, header and GitHub social picture
                    (python3 cards.py <out dir> 1.0; needs Playwright Chromium, numpy and scipy);
                    thumbnail.png is the Arsenal icon build.py uses; fonts/ (SIL Open Font License)

Run them from this folder.
