# BatteryLens

Drive the app with `batterylens` (the app binary; `batterylens help`). See `.claude/skills/batterylens/SKILL.md`.
Commands live in `App/Agent/AgentCommands.swift`; test them on a Debug build with `APP_STORE=/tmp/<name>`, which
starts a test copy on that folder's devices.json and history.jsonl with its own settings and no battery sources
(Release builds ignore it).
