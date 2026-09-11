# Issue tracker: GitHub

Issues and specs live in GitHub Issues. Use the `gh` CLI.

Infer the repository from `git remote -v`. If no GitHub remote is
configured, obtain the repository URL from the user before tracker
operations.

## Operations

- Publish a spec or ticket: `gh issue create --title "..." --body-file <path>`.
- Fetch a ticket: `gh issue view <number> --comments`.
- Inspect labels: `gh issue view <number> --json labels`.
- List issues: `gh issue list --state open --json number,title,body,labels`.
- Comment: `gh issue comment <number> --body-file <path>`.
- Apply a label: `gh issue edit <number> --add-label "<label>"`.
- Remove a label: `gh issue edit <number> --remove-label "<label>"`.
- Close: `gh issue close <number>`.

For multiline bodies, write the exact text to a temporary file and pass
it with `--body-file`. Use `triage-labels.md` for triage label names.

## Pull requests as a triage surface

**PRs as a request surface: no.**
