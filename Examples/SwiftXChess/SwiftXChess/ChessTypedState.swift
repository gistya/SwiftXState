// The TypeState/Brand facade for the chess machine lived here — `ChessGameState` /
// `ChessCastlingRegion` / `ChessCastlingSide(State)` / `ChessCastlingAvailability` brands plus
// `TypedSnapshot where Brand == …` projections (gamePhase, castlingRights), the `ChessViewState`
// `mapState` mapper, and a `CastlingRights(stateValue:)` init.
//
// Phase 3 of the Plan D migration removed all of it: it was dead code. The views derive their state
// from `session.context` (a `ChessContext`, which carries its own board / turn / castlingRights /
// outcome) and `session.snapshot`, never from the machine-state brands; with `ChessSession` moved onto
// `MachineActor<ChessGameMachine>` the `TypedActor` / `TypedSnapshot.typed(as:)` Brand facade is gone.
// Reach for the typed `Configuration<ChessState>` via `session.machineActor.configuration` if a future
// view needs the live `game.*` / `castling.*` region states.
