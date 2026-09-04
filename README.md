 **InkMate**
 
InkMate is a suite of classic board games designed specifically for KOReader on e-ink devices with fully integration with LICHESS API for online matches.

* **OFFLINE MODE**
  

* **How to Play Offline**
  
Open InkMate from your KOReader plugins menu.

Tap Play offline on the startup screen (or the main menu).

You will be taken directly to the game board. From here, you can start playing immediately.

To customize your game, tap the Gear Icon (Settings) in the bottom left corner:

Game Selection: Switch between Chess, Checkers, Reversi, and Fox & Hounds.

Engine Settings: Adjust Stockfish's skill level (0-20), think time, search depth, and blunder chance to match your skill.

Time Controls: Set up a local chess clock for blitz or rapid games.

Visuals: Toggle move hints, check highlights, or invert the opponent's pieces for a comfortable "table-top" Human vs. Human match on your e-reader.

* **LICHESS MODE**
  
InkMate features full integration with the Lichess API, allowing you to play against real people online directly from your e-reader!

**How to Connect to the Lichess API**

To play online, you need to provide InkMate with a personal Lichess API token.

Sign in to your account at lichess.org.

Go to the API token creation page: https://lichess.org/account/oauth/token/create.

Select the necessary scope: You must enable "Play games with the board API" (board:play) and "Puzzles" (Puzzle:write).

Click Create and copy the generated token (it will start with lip_.......).

Open InkMate, go to Settings > Play on Lichess... and paste your token.

Note: You must be connected to Wi-Fi, and your device must have curl installed to communicate with the server.


**Online Features**

* **Lichess Dashboard:** Once connected, you can access the dashboard to Seek a new opponent (matchmaking) or Resume an ongoing game that you are currently playing on your account.

* **Quick Time Controls:** When seeking an opponent, easily choose between standard presets for Blitz (3+0, 3+2, 5+0, 5+3) and Rapid (10+0, 10+5, 15+10), along with your preferred color and whether the game is Rated or Casual.
  
* **Daily Puzzles:** Challenge yourself with the official Lichess Daily Puzzle fetched directly from their servers.
  
* **Fair Play Mode:** **To ensure compliance with Lichess Terms of Service and prevent cheating, playing online automatically hides engine evaluations, disables move hints, and locks the undo/redo functionality.**
  
* **In-Game Actions**: The toolbar adapts during online play, swapping out local functions (like "Load PGN") for an online actions menu where you can **Offer a Draw, Propose a Takeback, or Resign.**

Installation
Copy inkmate.koplugin/ into your KOReader plugins directory:

Kobo: /mnt/onboard/.adds/koreader/plugins/
Copy the appropriate Stockfish binary into inkmate.koplugin/engines/:

Kobo and other ARM e-ink readers: a compatible stockfish ARM binary is included, this step can be skipped.
If no valid engine is available inkmate will fall back to basic Goldfish engine.

On first launch you are asked for a Lichess token. Paste one to play online, or choose Play offline — everything except Lichess play works with no account and no network.

## License
This plugin is a derivative of kochess and CasualKochess, released under the GNU General Public License v3.
See `LICENSE` for full terms.

Based on Casualkochess by MJCopper https://github.com/MJCopper/casualkochess.koplugin
Based on Kochess © Victor Fariña https://github.com/coffman/kochess.koplugin  
Based on the original kochess by Baptiste Fouques https://github.com/bateast/kochess  
Chess logic provided by: https://github.com/arizati/chess.lua  
Icons derived from: Colin M. L. Burnett (GPLv2+)
