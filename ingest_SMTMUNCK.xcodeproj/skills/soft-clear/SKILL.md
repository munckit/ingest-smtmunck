---
name: soft-clear
description: Use when the user writes -clear (or clear/start fresh) without opening a new chat. Applies a soft reset by ignoring prior conversational context and using only current codebase state plus the latest user request.
---

# Soft Clear

This skill provides a conversational reset pattern when true chat clearing is not available in the client.

## Trigger
Use this skill when the user writes `-clear`, `clear`, or asks for a clean slate/new start in the same thread.

## Behavior
1. Confirm that this is a soft reset, not a true chat/session deletion.
2. Acknowledge reset mode in one line.
3. From this point, prioritize only:
- current repository/workspace state
- AGENTS.md and system/developer instructions
- the latest user request
4. Do not rely on previous solution proposals unless the user explicitly references them.
5. Keep responses concise and execution-focused.

## Response Template
`Soft reset active. I will ignore earlier conversation context and proceed from current codebase state plus your latest request.`

## Constraints
- Do not claim chat history was deleted.
- Do not claim client/session state was reset.
- If user needs true reset, instruct them to start a new conversation in the UI.
