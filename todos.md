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

- Works only with phones in the same local network.
- One host device is the source of truth.

**Host**:
- Create/select game
- Add players
  - Guests with a phone join via local network discovery and code entry
  - Players without a phone do not need a device; host enters their bets and tricks in the game session
- Advance rounds / finalize round
- Edit/undo (including all players’ bets/gots — host is source of truth)
- Starts and ends a multiplayer session (guests join this session); game can start before every slot has a connected device
- Broadcasts authoritative `currentGame` snapshots to all guests after every accepted command

**Guest**:
- Read-only view of game state + scoreboard
- Can submit:
  - their own bet for the current round
  - their own got for the current round
- Cannot: create/select games, change players, change dealer, edit bets/gots, edit other players’ inputs
- If disconnected, can re-join and receive the latest `currentGame` snapshot
