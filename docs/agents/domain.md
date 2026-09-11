# Domain docs

This repository uses a single-context layout:

- `CONTEXT.md` at the repository root holds domain terminology.
- `docs/adr/` holds architectural decision records.

## Before exploring the codebase

Read `CONTEXT.md` and any ADRs relevant to the area being explored.

If these files do not exist, proceed silently. The domain-modeling
skill creates them when terminology or decisions are resolved.

## Use the glossary vocabulary

Use terms defined in `CONTEXT.md` in issue titles, proposals,
hypotheses, and test names. Respect explicitly avoided synonyms.

If a needed concept is missing, reconsider the terminology or note
the gap for domain-modeling.

## Surface ADR conflicts

If a proposal contradicts an existing ADR, identify the ADR and
explain why its decision should be reconsidered.
