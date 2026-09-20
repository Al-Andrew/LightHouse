# Give external file tools a separate temporary terminal

F4 opens a temporary terminal session covering the full LightHouse application
area; exiting the tool returns to the Panes, without a background tool workflow.
The tool does not run through the persistent shell, so opening a file preserves
that shell's working directory, input, and running program. This requires a
separate tool lifetime, which is justified by the file-opening feature rather
than by a speculative terminal-session refactor.
