# AGENTS.md

## Soft Clear Shortcut
1. If user writes `-clear` (or asks to start fresh in the same thread), trigger the `soft-clear` skill at `skills/soft-clear/SKILL.md`.
2. Treat it as a soft reset only (ignore prior conversational context, but do not claim chat history was deleted).

## Project Purpose
This app is a kiosk-style ingest tool for macOS.
Primary flow:
1. Detect external source disk.
2. Find latest valid project folder on that disk.
3. Let operator choose production folder (or create one).
4. Copy source project folder to `/Volumes/FILM/...`.
5. Try to unmount/eject source disk safely.
6. Return to idle state.

## Definition of Done
A change is done when all are true:
1. Requested behavior is implemented with minimal scope.
2. No unrelated refactors are introduced.
3. `ContentView.swift` has no new diagnostics.
4. User-facing Swedish text remains consistent unless explicitly requested.

## Scope and Safety Rules
1. Prioritize correctness and operational safety over cosmetic changes.
2. Do not change mount roots (`/Volumes/FILM`, `/Volumes`) unless explicitly requested.
3. Do not remove timeout/eject/error handling logic unless explicitly requested.
4. Keep state-machine behavior predictable (`idle`, `diskDetected`, `selectProduction`, `transferring`, `done`).

## Code Style
1. Keep SwiftUI code simple and explicit.
2. Use `@State private var` for local UI state.
3. Avoid force unwraps.
4. Keep function names descriptive and behavior-specific.
5. Keep comments short and only for non-obvious logic.

## How to Work on This Project
1. Read the relevant code path before editing.
2. Explain intended change briefly before making edits.
3. Make the smallest change that solves the request.
4. Validate with `XcodeRefreshCodeIssuesInFile` on touched Swift files.
5. If change impacts broader flow, run full build.

## Testing Expectations
When relevant, verify at least:
1. Disk detection transitions correctly from `idle` to `diskDetected`.
2. Selection timeout behavior in `selectProduction`.
3. Folder create flow (`enterName` -> `confirmName` -> create).
4. Transfer success path and error path.
5. Done-screen behavior for both auto-eject success and manual eject fallback.

## Communication Preferences for Assistant
1. Keep responses concise and practical.
2. State what changed and why.
3. Call out risks or assumptions clearly.
4. If blocked, ask one clear question with options.

## Commit Guidance
1. Use small, focused commits.
2. Commit message format:
   - `feat: ...` for behavior additions
   - `fix: ...` for bug fixes
   - `refactor: ...` for non-behavior changes
3. Do not mix unrelated changes in the same commit.
