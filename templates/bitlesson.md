# BitLesson Knowledge Base

This file is project-specific. Keep entries precise and reusable for future rounds.

## Entry Template (Strict)

Use this exact field order for every entry:

```markdown
## Lesson: <unique-id>
Lesson ID: <BL-YYYYMMDD-short-name>
Scope: <component/subsystem/files>
Problem Description: <specific failure mode with trigger conditions>
Root Cause: <direct technical cause>
Solution: <exact fix that resolved the problem>
Constraints: <limits, assumptions, non-goals>
Validation Evidence: <tests/commands/logs/PR evidence>
Source Rounds: <round numbers where problem appeared and was solved>
```

## Deprecation

To retire a superseded or obsolete lesson, do not delete it. Keep the entry (its ID must
still resolve) and append a status line so the selector skips it and the history is preserved:

```markdown
Status: deprecated — <reason / superseded by BL-YYYYMMDD-short-name>
```

Report the retirement in the round summary with `Action: deprecate` and the Lesson ID(s).

## Entries

<!-- Add lessons below using the strict template. -->
