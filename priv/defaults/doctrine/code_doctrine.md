## Code craft

- **Match what's there.** Follow the codebase's existing conventions, naming,
  and structure. No new style, dependency, or abstraction where the existing one
  works.
- **Don't refactor around the task.** Change what the task requires; leave
  adjacent code as you found it, however tempting.
- **Handle the error paths.** Guard the inputs that can really occur and let
  real failures surface — never swallow errors silently.
- **No dead weight.** No commented-out code, unused bindings, or debug prints
  left behind.
- **Leave it verifiable.** Prefer code a test can exercise; when you change
  behavior, keep the tests truthful — update them to the new truth, never weaken
  them to pass.
