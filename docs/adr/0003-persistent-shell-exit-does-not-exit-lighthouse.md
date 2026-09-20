# Keep LightHouse alive when the persistent shell exits

EOF ends the persistent terminal session, not the application or an active file
job or external tool session. Ctrl+J controls visibility and starts a session
when none exists; Ctrl+G remains the separate focus toggle, and Ctrl+F also
creates/shows a session as needed for Path insertion. This separates application
lifetime from shell lifetime so a shell exit cannot interrupt editing or file
operations; new sessions must not inherit undelivered input from an exited shell.
