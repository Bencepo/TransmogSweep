# Notes for Claude

TransmogSweep: auction house tab for WoW Forever (modern C_AuctionHouse and C_TransmogCollection APIs, Lua 5.1) that lists uncollected transmog appearances and buys them top to bottom. Author and rights holder: Bencepo. All rights reserved, no open-source license.

## Layout

- `TransmogSweep.lua`: everything (scan, collected checks, list, buying, window, settings, events).
- `Libs/BencepoUI`: shared settings-window toolkit (also in VendorFloor and ProcFlare). Bump the LibStub minor version on every change so the newest copy wins. `opts.bugUrl` gives the "Report a bug" button.
- `Libs/LibAHTab`: the auction house tab (same library as Auctionator and VendorFloor).
- `media/logo.png`: project logo for CurseForge, Wago and the website (not packaged).

## What was learned in game (Forever)

- Scan with `SendBrowseQuery` filtered to item classes 2 and 4, not `ReplicateItems`: the full scan reads 250k+ auctions and is slow.
- The source ID comes from `C_TransmogCollection.GetItemInfo(itemID)`. `ItemKeyInfo.appearanceLink` is only used when `GetSourceInfo(id).itemID` matches the item.
- `AccountCanCollectSource` returning `hasData=true, canCollect=false` means the look is settled for the account (tooltip shows no collection line): leave it out. The collection API still reports `isCollected=false` for those.
- The tooltip line ("You haven't collected this appearance" / "...but not from this item") is the verdict shown to the player and wins over the API. Fallback to the API when no tooltip shows any such line (transmog switched off on the character).
- Forever's auction house sends `AUCTION_HOUSE_SHOW_ERROR` 10 (DatabaseError, "Internal auction error") about 0.1 s after a buyout that then completes. It is hidden right after our own bid and only counts as a failure when no `AUCTION_HOUSE_PURCHASE_COMPLETED` follows within 2 s.
- Item search results can be stale from the cache: read only after `ITEM_SEARCH_RESULTS_UPDATED` for our item key (or 2.5 s), and wait 0.8 s after a purchase before the next search.
- Recipes (item class 9, subclass per profession): known comes from the tooltip line `ITEM_SPELL_KNOWN`, cached per character. In Forever's recipe tooltip "Requires <Profession> (n)" comes after the "Use:" line, and recipes that make an item show that item's tooltip in between (with its own "Requires Level"). So the last skill line counts, compared with the character's rank as well as by its red colour; "Requires Level" is ignored.
- The list keeps the scanned price and a fixed tie order (price, name, source); after a purchase only that row is removed, no rebuild, so the next row stays under the cursor.

## Rules

- UI texts in English. Buttons in the UI instead of chat commands. Settings in the BencepoUI window, not in Blizzard's options.
- Every purchase needs a click (hardware event); never buy automatically.
- CI runs luacheck and LuaLS with the WoW API annotations; LuaLS must report zero diagnostics or the release stops. New Blizzard globals go into `.luarc.json`.
- Release: new version heading at the top of `CHANGELOG.md` (`## 1.0.1`), push to `main`; the workflow tags, builds and uploads to CurseForge and Wago (secrets `CF_API_KEY`, `WAGO_API_TOKEN`). The release reaches players right away, so test changes in the game before pushing.
