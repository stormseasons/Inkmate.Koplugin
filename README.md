# Casual Chess & Board Games for KOReader E-Ink Devices
Casual Chess, Checkers, Reversi and Fox & Hounds plugin for KOReader, designed for Kobo and other ARM e-ink devices (Kindle, PocketBook, Cervantes, Remarkable).
Chess has been derived from the work by Baptiste Fouques & Victor Fariña

Contributions by [kbarni](https://github.com/kbarni) to Reversi and Fox & Hounds AI engines.

---

## Download
https://github.com/MJCopper/casualkochess.koplugin/releases/download/v2.0.2/casualkochess.koplugin.v2.0.2.zip

---

## Features
- Play Human Vs Human, Human Vs Computer, Computer Vs Computer.
- Play real opponents online on **lichess.org** via the Board API (see below).
- Play chess against the Stockfish engine.
- Completely offline, no internet required (except for Lichess play).
- Pre-defined difficulty levels.
- Adjustable computer skill level (0–20).
- Adjustable computer think time (1–10 seconds).
- Adjustable computer search depth (1-ThinkTime).
- Adjustable blunder chance (0%-60%), Creates the possibilty for Stockfish to makes mistakes, plays more like a casual human.
- Custom Goldfish AI for chess as a fall-back when Stockfish engine fails to load. - It's not very smart, but still playable.
- Switch between Chess, Checkers, Reversi and Fox & Hounds
- Setting to invert pieces at "top of screen" end of board for a more natural Human Vs Human game.
- Learning hints, shows valid moves for selected piece.
- Checkmate, Draw, Stalemate & 50-Move Rule detection.
- Chess clock with configurable time controls per player (base time + increment).
- Opening detection with ECO code display.
- Position evaluation display.
- PGN save and load.
- Game state saved and restored on close/re-open.
- Designed for casual play, defaults set to a friendly difficulty.

---

## Playing on Lichess

Casual Chess can use lichess.org as the opponent instead of the local engine. The
board, rules, clock and PGN log are the same; only the opponent changes.

**Setup**

The first time you open Casual Chess it asks for a Lichess API token. Either
paste one and tap **Play on Lichess**, or tap **Play offline** to skip — you can
add the token later under the gear icon → **Play on Lichess...**

To get a token:

1. Sign in at lichess.org
2. Open <https://lichess.org/account/oauth/token/create?scopes[]=board:play>
3. Tick **"Play games with the board API"** (`board:play`) and nothing else, then
   **Create**
4. Copy the token — Lichess shows it only once — and paste it into the plugin

From there, **Seek a new opponent** pairs you with someone at the chosen time
control, or **Resume an ongoing game...** lists games you already have running.
The `+` toolbar button ends the current online game and seeks a new one.

**Requirements**

- A network connection, and the `curl` binary on the device. Most Kobo and Kindle
  firmwares do not ship `curl`; if it is missing the plugin says so on startup.
  Put a static `curl` for your architecture on the device and set
  `lichess_curl_path` in `casualkochess.lua` to its full path.

**What changes in online mode**

- Undo, redo and the engine evaluation are disabled, and the move-hint overlays
  are hidden. Engine assistance during a Lichess game violates their Terms of
  Service and gets accounts banned.
- Lichess owns the clock and the game result; the local clock follows the server.
- The board orientation follows the colour Lichess dealt you.

**Note on the token**: it is stored unencrypted in KOReader's settings on the
device. Use a token scoped to `board:play` only, and revoke it if the device is
lost.

---

## Installation
1. Copy `casualkochess.koplugin/` into your KOReader plugins directory:
   - Kobo: `/mnt/onboard/.adds/koreader/plugins/`

2. Copy the appropriate Stockfish binary into `casualkochess.koplugin/engines/`:
   - Kobo and other ARM e-ink readers: a compatible `stockfish` ARM binary is included, this step can be skipped.
   - If no valid engine is available Casual Chess will fall back to basic Goldfish engine.

3. Restart KOReader. The plugin appears in the main menu as **Casual Chess**.

4. On first launch you are asked for a Lichess token. Paste one to play online,
   or choose **Play offline** — everything except Lichess play works with no
   account and no network.

---

## Screenshots

<p align="center">
  <img src="screenshots/chesshints.jpg" alt="Hints" width="300" style="padding: 16px;">
  <img src="screenshots/checkers.jpg" alt="Checkers" width="300" style="padding: 16px;">
  <img src="screenshots/settings.jpg" alt="Settings" width="300" style="padding: 16px;">
  <img src="screenshots/interface.jpg" alt="Settings" width="300" style="padding: 16px;">
</p>

---

## License
This plugin is a derivative of kochess, released under the GNU General Public License v3.
See `LICENSE` for full terms.

Based on Kochess © Victor Fariña https://github.com/coffman/kochess.koplugin  
Based on the original kochess by Baptiste Fouques https://github.com/bateast/kochess  
Chess logic provided by: https://github.com/arizati/chess.lua  
Icons derived from: Colin M. L. Burnett (GPLv2+)
