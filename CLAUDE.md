# ClickLens

Drive the app with `clicklens` (the app binary; `clicklens help`). See `.claude/skills/clicklens/SKILL.md`. Commands live in
`Sources/ClickLens/Agent/AgentCommands.swift`; test them on a Debug build (`swift build`) with `APP_STORE=/tmp/<name>`,
which starts a test copy on its own settings with no effects, overlays, shortcuts or sync (Release builds ignore it).
