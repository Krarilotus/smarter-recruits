# UCP integration review

Recruit settings now have short descriptions in every UCP launcher language. In-game rally and stance tips use the game language; diagnostic logging is off by default.

Separates correction and quality-of-life groups, declares dependencies, adds aligned defaults and a runtime allowlist. In-game labels use textResourceModifier 0.3.0 at afterInit, not a private encoder. Detailed documentation stays in the README. Existing recruit mechanics are preserved.

## Remaining native work

The group-creation hook and recruit rally/stance behavior overlap troop-behavior and AIC owners and must be coordinated before wider integration. Private MARKS/FOLLOW_UIDS/last-position state has no demonstrated save/load/replay lifecycle. UID checks are useful but do not prove restoration. Native portrait rendering also needs an owner/API-gap review.

Inspected upstream parent: `183adea782bf57b2f8b8537a219fac698df496ae`. Launcher locales follow
`UCP3-GUI/resources/lang/languages.yaml` (de, en, fr, ru, hu, tr, ch, es, fa).
Category identities follow the current Legacy/GUI catalog, including its existing
English category fallback; setting and description text has full locale entries.
Human translation review and installed GUI/RTL layout checks are pending.

Text reuse: textResourceModifier 0.3.0 at `5ab58fa`, `init.lua` exports
`GetLanguage` and `TransformText`; `textResourceModifier.cpp` reads CR.TEX
and owns UTF-8-to-game-codepage conversion. Framework `content/ucp/code/hooks.lua`
fires `afterInit` immediately before the Windows message loop. The existing
Improved Tunnelers caller uses that phase. Only labels and pointer tables change;
no text dispatch, encoder or game-state owner is duplicated. All eleven native
language catalogs have encodable labels; game font/RTL layout still needs testing.

Offline checks passed: YAML/default consistency, actual GUI control types,
all referenced locale keys, Lua 5.4 syntax and runtime package inputs. Runtime
allowlists exclude research/bench Python. These are not game/editor/save/replay
acceptance. Multiplayer testing belongs to players. No Store release is claimed.
