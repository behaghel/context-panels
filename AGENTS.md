# Context Panels agent instructions

Follow [the Context Panels development notes](AGENT.md).

Before repository edits, load the `agent-session` skill. Managed worktrees are required. If the skill or verified launcher is unavailable, stop and ask. Enter `devenv shell` for the project launcher, or invoke `devenv -q shell -- agent-session` from the project. The module does not configure Pi or launch an agent on shell entry.
