---
name: commit-and-push
description: Use when the user asks to commit, commit and push, save/sync changes to git, or open a commit for the current diff — in any language.
---

# Commit and Push

Slice the working tree into cohesive commits, then push once. Messages follow
Conventional Commits with a gitmoji prefix and are **always written in
English**, even when the user is chatting in another language.

## Workflow

1. Read the actual changes: `git status`, `git diff`, `git diff --cached`.
   Never guess a diff from memory. Skim `git log --oneline -10` for the
   repo's message tone.
2. Group the changed files into slices (see below), then for each slice:
   - Stage its files by name (`git add <path> ...`) — never `git add -A` or
     `git add .`. Re-check `git status` to confirm nothing unintended came
     along.
   - Commit it with a HEREDOC so formatting survives:

     ```bash
     git commit -m "$(cat <<'EOF'
     ✨ feat(scope): add thing
     EOF
     )"
     ```
3. Push once, after all commits exist: `git push`, or `git push -u origin
   <branch>` if the branch has no upstream yet. If the push is rejected,
   stop and tell the user.
4. Verify with `git status` and `git log --oneline` — don't assume success.

## Slicing

Group the changed **files** by the goal they serve; one commit per group.
Mixed types in the working tree — a refactor, a doc update, a feature, a fix
— are the strongest signal to slice, since no single message describes them
honestly. Order slices so history reads forward: refactors and dependencies
first, then features, then docs and chores.

- **The file is the atom.** Never split one file across commits — no
  `git add -p`, no hunk staging. A file whose changes mix goals is committed
  whole, under the type fitting the bulk of its diff.
- **Keep each slice coherent**: source, its tests, and the types or fixtures
  it needs belong together.
- **Don't over-slice.** Files that only make sense together are one commit,
  and a tree that genuinely serves one goal is one commit — just say so.

## Message format

```
<emoji> <type>(<scope>): <description>
```

| type       | emoji | when                                       |
|------------|-------|--------------------------------------------|
| `feat`     | ✨    | new feature                                |
| `fix`      | 🐛    | bug fix                                    |
| `docs`     | 📝    | documentation only                         |
| `style`    | 🎨    | formatting, no meaning change              |
| `refactor` | ♻️    | neither fixes a bug nor adds a feature     |
| `perf`     | ⚡️    | performance                                |
| `test`     | ✅    | adding or correcting tests                 |
| `build`    | 📦️   | build system or dependencies               |
| `ci`       | 👷    | CI config or scripts                       |
| `chore`    | 🔧    | anything else outside src and test         |
| `revert`   | ⏪️    | reverts a previous commit                  |

- `<scope>` is optional — use it when the change sits in one clear area.
- `<description>`: short, imperative, lowercase, no trailing period, English.
- Add a body only when the "why" isn't obvious from the diff; wrap at ~72
  characters.

## Rules

- **Never add a co-author trailer.** No `Co-Authored-By: Claude`, no other
  agent or tool, no exceptions — commits are authored by the user alone.
- Never split a single file's changes across commits or stage partial hunks.
- Never stage files that may hold secrets (`.env`, credentials, keys,
  tokens) — flag them to the user instead.
- Never use `--no-verify`, and never use destructive git commands
  (`reset --hard`, `push --force`, …) as part of this workflow.
- Only commit and push when the user asks in this conversation; this skill
  doesn't grant standing permission to commit proactively.
