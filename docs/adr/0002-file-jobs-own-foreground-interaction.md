# Keep file jobs in the foreground until result dismissal

Copy, move, delete, and directory creation block interaction with the persistent
terminal until their result is dismissed, including while waiting for conflict
or error decisions. The shell and its running program continue executing, and
LightHouse continues collecting output; the restriction is on user interaction.
This deliberately replaces the previous Ctrl+G access during jobs with one
foreground workflow, so future changes should not restore concurrent terminal
interaction merely to preserve the old routing behavior.
