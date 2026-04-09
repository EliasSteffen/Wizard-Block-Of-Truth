# Wizard

The idea is to build a mobile app which replaces the piece of paper to account all the points in the game "Wizard".

The rules of the classic game can be found here: https://blog.amigo-spiele.de/content/ap/rule/06900-GB-AmigoRule.pdf

## Design

This app will be deployed for iPhones. Therefore I would like to use swift and the modern liquidGlass (https://developer.apple.com/documentation/technologyoverviews/liquid-glass) look.
Furthermore make use of many apple design guidelines (https://developer.apple.com/documentation/technologyoverviews/app-design-and-ui)

### Technical design decisions

- **Platform**: iPhone only
- **Minimum iOS**: latest iOS version that supports Liquid Glass
- **UI framework**: SwiftUI
- **Persistence**: SwiftData (local on-device)
- **Multiplayer (local network)**:
  - Discovery: Bonjour (`_wizard-score._tcp`)
  - Transport: WebSocket (host is server; guests are clients)
  - Authority: host is the single source of truth

### UI/UX (Liquid Glass, iPhone)

Goal: replace the paper sheet with an interface that is **fast, glanceable, and hard to mess up**.

- **Navigation**
  - Keep it shallow: `GameList` → `GameSession` (main screen), with modals/sheets for entering bets/got.
  - Always show “where am I”: current round (hand size), current dealer, and whether the round is finalized.

- **Primary screen layout (GameSession)**
  - Top: compact header with **Round**, **HandSize**, **Dealer**.
  - Center: “Scoreboard” as a glass card list (player name + total points + last delta).
  - Bottom: a prominent primary action that matches state:
    - If bets missing: “Enter Bets”
    - Else if got missing: “Enter Got”
    - Else: “Finalize Round”

- **Input UX**
  - Use a bottom sheet for “Enter Bets” and “Enter Got” with one row per player.
  - Prefer **stepper/picker** controls (0…handSize) over free text to reduce input errors.
  - Provide immediate validation:
    - show sum of bets and sum of got live
    - clearly highlight invalid state before allowing finalize

- **History & editing**
  - History is a secondary screen or expandable section: round-by-round table (bet, got, delta).
  - Editing past rounds should be explicit (e.g. “Edit history” mode) and show a warning that totals will be recomputed.

- **Multiplayer cues**
  - Always indicate device role in the header:
    - Host: “Hosting”
    - Guest: “Connected to <HostName>”
  - Guests should only see the controls for their own bet/got; other rows are read-only.

- **Accessibility & polish**
  - Dynamic Type friendly layout (avoid tight tables that break at large sizes).
  - High-contrast readable text on glass surfaces; avoid relying on translucency alone.
  - Haptics for key actions (submit, finalize, undo).

### Architecture

The app is split into a **Model/Domain layer** and a **UI layer**. The UI never mutates the model directly; it only renders the current game state and sends commands.

- **Model/Domain**
  - Contains: `Game`, `Player`, `Round`, `RoundEntry`, scoring, progression, validation
  - Pure logic: deterministic and testable (no SwiftUI, no networking, no persistence)
  - One mutation API: apply `GameCommand`s (e.g. `SubmitBet`, `SubmitGot`, `FinalizeRound`, `UndoLastRound`, `EditRoundEntry`)

- **Coordinator/Store (App layer)**
  - Exposes: `currentGame: Game?` (single source for the UI)
  - Responsibilities:
    - load/save games (SwiftData)
    - select/create games
    - multiplayer host mode: receive guest commands → validate/apply to `currentGame` → broadcast updated `currentGame` snapshot

- **UI (SwiftUI)**
  - Renders `currentGame`
  - Sends user intents as `GameCommand`s to the coordinator/store
  - Keeps only temporary input state locally (e.g. textfield editing) until a command is submitted

## Functionality

The game works round by round.
Each round works like this:
1. Each player places a bet (how many tricks they will take)
2. Bets are recorded
3. The round is played (outside the app)
4. Each player reports how many tricks they actually took
5. The app calculates point changes for each player
6. The next round begins

### Round progression

- Hand size in a new game always starts at 1.
- Hand size increases by 1 each round.
- The game ends after reaching the maximum hand size.
  - Classic deck size is 60 cards (52 + 4 Wizards + 4 Jesters).
  - Therefore \(maxHandSize = floor(60 / playerCount)\).

### Scoring

Let \(b\) = bet, \(g\) = got.

- If \(b = g\): pointsDelta = 20 + 10 * b
- Else: pointsDelta = -10 * abs(b - g)

### Input constraints

- For each player: bet is an integer in [0, handSize]
- For each player: got is an integer in [0, handSize]

### Dealer Rotation

- Dealer rotates each round: next player in list (wrap around)

### Models

- Rounds are append-only while playing:
  - The current round is the last round in `Rounds` (index = `CurrentRoundIndex`)
  - After a round is finalized, a new round is appended automatically

**Mode**:
- Single-Phone
- Multi-Phone

**Player**:
- Name: string
- Id: string

**RoundEntry**:
- Bet: integer
- Got: integer
- PointsDelta: integer (computed scoring)

**Round**:
- HandSize: integer
- Dealer: PlayerId
- Entries: [PlayerId: RoundEntry]

**Game**:
- Name: string
- Id: string
- Players: [Player]
- Mode: Mode
- Rounds: [Round]

**GameManager**:
- Games: [Game]

### Modes

#### Single-Phone

- **Start**
  - Show existing games (continue) + "New game"
  - New game: select player count (2-6), enter player names, pick starting dealer
- **Game screen**
  - Show scoreboard (totals) and current round (hand size, dealer)
  - Actions:
    - Show history
      - Bets, Got, PointsDelta for each round as a table
    - Enter bets for current round
      - After entering it is assumed the game is started/played (outside the app)
    - Enter got for current round
      - After etering it is assumed the round has ended (therefore give the option on last got input to finalize round and proceed to next one)
    - Finalize round (computes deltas, updates totals, advances dealer, creates next round)
    - Edit round inputs
      - Select round (Default is current)
      - Edit input
      - If a finalized past round is editd, recompute points from that round onward


#### Multi-Phone

- Works only with phones in the same local network.
- One host device is the source of truth.

**Host**:
- Create/select game
- Add players
- Advance rounds / finalize round
- Edit/undo
- Starts and ends a multiplayer session (guests join this session)
- Broadcasts authoritative `currentGame` snapshots to all guests after every accepted command

**Guest**:
- Read-only view of game state + scoreboard
- Can submit:
  - their own bet for the current round
  - their own got for the current round
- Cannot: create/select games, change players, change dealer, finalize/undo rounds, edit other players’ inputs
- If disconnected, can re-join and receive the latest `currentGame` snapshot
