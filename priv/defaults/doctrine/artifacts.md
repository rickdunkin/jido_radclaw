## Runtime artifacts

If you discover runtime details that differ from the expected configuration — a
server URL, a bound port, generated file paths — report them in your output's
`artifacts` field as string values (`url`, `port`, `files`).

Use an empty object (`{}`) when there are none. Never invent values: report only
what you actually observed.
