---
name: jido-framework
description: "Use this skill working with Jido Framework. Consult this when working with the agent layer, agents, prompts, templates, workers etc."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [jido](references/jido.md)
- [jido_action](references/jido_action.md)
- [jido_ai](references/jido_ai.md)
- [jido_composer](references/jido_composer.md)
- [jido_memory](references/jido_memory.md)
- [jido_messaging](references/jido_messaging.md)
- [jido_shell](references/jido_shell.md)
- [jido_signal](references/jido_signal.md)
- [jido_vfs](references/jido_vfs.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p jido -p jido_action -p jido_ai -p jido_browser -p jido_composer -p jido_mcp -p jido_memory -p jido_messaging -p jido_shell -p jido_signal -p jido_skill -p jido_vfs
```

## Available Mix Tasks

- `mix jido.gen.agent` - Generates a Jido Agent module
- `mix jido.gen.plugin` - Generates a Jido Plugin module
- `mix jido.gen.sensor` - Generates a Jido Sensor module
- `mix jido.install` - Installs Jido in your project
- `mix jido_action.gen.action` - Generates a Jido Action module
- `mix jido_action.gen.workflow` - Generates a Jido Workflow using ActionPlan
- `mix jido_action.install` - Installs and configures jido_action in your project
- `mix jido_ai` - Run Jido AI from the command line (one-shot or stdin)
- `mix jido_ai.install` - Install and configure Jido AI for use in an application.
- `mix jido_ai.install.docs`
- `mix jido_ai.quality` - Run final stable quality checkpoint and traceability closure validation
- `mix jido_ai.skill` - Manage and inspect Jido AI skills
- `mix compile.jido_browser` - Checks for Jido.Browser binary dependencies
- `mix jido_browser.install` - Install browser automation binaries (agent_browser, web, vibium)
- `mix jido.messaging.demo` - Runs a demo messaging service (echo, bridge, or agent mode)
- `mix jido_shell` - Start interactive Jido.Shell
- `mix jido_shell.guardrails` - Validate Jido.Shell namespace/layout guardrails
- `mix jido_shell.install` - Install and configure Jido Shell for use in an application.
- `mix jido_shell.install.docs`
- `mix jido_signal.install` - Install and configure Jido Signal for use in an application.
- `mix jido_signal.install.docs`
- `mix skill.list` - List discovered skills from the terminal
- `mix skill.reload` - Reload skills and runtime settings from disk
- `mix skill.routes` - List active skill routes from the dispatcher
- `mix skill.run` - Publish a skill route signal from the terminal
- `mix skill.signal` - Publish a skill signal on the Jido signal bus
- `mix skill.watch` - Watch skill signals on the Jido signal bus
- `mix jido_vfs.install` - Install and configure Jido VFS for use in an application.
- `mix jido_vfs.install.docs`
<!-- usage-rules-skill-end -->
