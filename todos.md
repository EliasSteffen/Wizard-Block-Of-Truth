# Todos

- [ ] Add Multiphone mode
- [ ] Add Game rules for each card
- [ ] Add Gamemode, which enables the players (host and guests) to see what the other players have bet until the round is finished.

- reihenfolge ist anders, wenn es ein multi phone game ist.
  - zuerst das game erstellen mit den players
  - dann joinen die guests
  - dann werden die namen (durch die guests beim joinen) festgelegt
  - dann wird der dealer festgelegt und die letzten änderungen in den regeln gespeichert
  - dann das game starten

## Multi-Phone

- Works only with phones in the same local network (wire protocol v2; app 1.1 guests are told to update).
- One host device is the source of truth; one hosted session at a time per device.

**Host**:
- Create/select game
- Arrange seats in the lobby: name phone-less players, reorder seats, unassign (kick) a guest's seat
  - Guests with a phone join via local network discovery (tap the session — no code typing; the code only identifies the session) and pick an open seat with their name
  - Players without a phone do not need a device; host enters their bets and tricks in the game session
- Set dealer and rules, then start (not every seat needs a device)
- Advance rounds / finalize round
- Edit/undo: can correct any single value; bulk entry sheets only cover phone-less players
- Declares Bomb / Cloud card on the host game screen
- Starts and ends a multiplayer session ("End session"); the session also ends automatically when the game is finished
- Session survives an app relaunch / screen lock (same code, guests reconnect automatically)
- Broadcasts authoritative `currentGame` snapshots to joined guests after every accepted command

**Guest**:
- Read-only view of game state + scoreboard
- Can submit (own seat, current round, round not finalized):
  - their own bet while not all bets are in (a bet that makes the bets add up to the hand size is rejected)
  - their own won tricks once all bets are in, until the host finalizes the round
- Cannot: create/select games, change players, change dealer, edit other players' inputs, run host-only commands
- If disconnected, reconnects automatically with the saved token and receives the latest `currentGame` snapshot
- Keeps a read-only copy of the final scoreboard when the game finishes
