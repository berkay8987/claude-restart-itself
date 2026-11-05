# restart-button

A one-press restart for Claude Code Desktop, and it puts you back in the
session you were in.

Picking up a new mod, or a change to one, means restarting the app. By hand
that is: quit, find the icon, open it, find the session again. This mod puts a
small **⟳** at the right-hand end of the band above the prompt. Press it, and
the app closes and comes back where you left off.

```
┌─ transcript ───────────────────────────────────────┐
│  ...                                               │
└────────────────────────────────────────────────────┘
  whatever else lives in the band              [ ⟳ ]
┌─ composer ─────────────────────────────────────────┐
│  Type a message...                                 │
└────────────────────────────────────────────────────┘
```

There is no confirmation step. If you press it, it restarts.

## Install

```
/plugin install restart-button --marketplace berkay8987/claude-restart-itself
```

Answer `y` to add the marketplace, then pick a scope (user scope is first;
press Enter). In the desktop app, where `/plugin` does not run: click **+**
next to the prompt box, then **Plugins**, **Add marketplace** with
`berkay8987/claude-restart-itself`, then **Add plugin**.

> [!WARNING]
> Windows only. The restart is done by a PowerShell helper that targets the
> Claude MSIX package, so it will not work on macOS or Linux as written.

## What a press actually does

1. Hands off to `scripts/restart.ps1`, which immediately re-launches itself
   through WMI (see below) and exits.
2. The surviving helper calls `CloseMainWindow()` on the windowed Claude
   processes and gives them a 600 ms grace period.
3. Anything still up is force-killed, and it polls at 50 ms until the process
   table is clear.
4. It waits a short settle window (`-SettleMs`, 1200 ms by default), then asks
   `explorer.exe` to open `claude://code/continue?session=last`, retrying once
   if the app does not appear.

   The settle window is not padding. Fire the deep link before Windows has
   finished tearing the package down and the shell has no handler to give it
   to: you get a plain File Explorer window instead of the app, and the app
   can come up without its plugins loaded.
5. If the app is still not back it falls back to `shell:AppsFolder`.

Every log line carries a `+NNNms` offset, so the cost of each phase is visible.
The script's own overhead is roughly 1.5 s; the rest of a restart is the app's
own cold start, which nothing here can speed up.

An earlier version waited a flat 8 seconds for a graceful close and then force-
killed everything anyway — on this machine all 12 processes were force-killed
on every single run, so the wait bought nothing. It also slept a fixed 2 s for
the instance lock instead of retrying. Removing both took about 10 seconds off.

Each step is appended to `%TEMP%\restart-claude.log`, which is the first place
to look if a restart stalls. Run the script with `-DryRun` to see what it would
close without closing anything.

## The one interesting bit

The obvious implementation does not work, and the reason is worth writing down.

Claude Desktop runs its child processes inside a **job object**. Killing the app
tears the whole job down, and a helper started with `Start-Process` inherits
that job — so the process whose only purpose is to restart the app gets killed
by the app's own death, a moment before it can do anything. The app closes and
never comes back, with no error anywhere.

A process created through WMI is parented to `WmiPrvSE` instead, which puts it
outside the job, and it survives:

| Spawn method | Parent | In job? | Survives |
| --- | --- | --- | --- |
| `Start-Process` | powershell | yes | no |
| `Invoke-CimMethod Win32_Process Create` | WmiPrvSE | no | yes |

That is the whole trick, and it is the only reason this mod works.

There is a second, related trap. The helper must not start the app itself: the
new app process would share the helper's console, so Claude's stdout appears in
a stray PowerShell window, and closing that window closes Claude with it. So
the helper hands the activation to `explorer.exe`, which passes it to the
already-running shell and exits, leaving no console anywhere in the app's
ancestry. The helper's own console is created hidden (`ShowWindow = 0` via
`Win32_ProcessStartup`), so nothing flashes up either. `CREATE_NO_WINDOW` and
`DETACHED_PROCESS` both look like the right answer here and neither works: WMI
rejects the first and PowerShell will not run under the second.

## Known limits

- **The button cannot go in the titlebar.** That is native window chrome; mods
  can only draw in the band above the prompt, a pane, the prompt hint, the
  session-mode row, and transcript components.
- **It reopens the last session, not strictly this one.** The deep link wants
  the desktop session's `local_...` id, which a mod has no way to read, so the
  helper passes `session=last`. In practice that is the session you just
  pressed the button in, since it has the most recent activity.
- **It closes the whole app**, not just one session. Other sessions get a
  graceful close first, so they should save, but unsaved work elsewhere is at
  risk.
- **Only one hook may draw the band, and order decides who wins.** This mod
  draws whatever the engine and other plugins put there and pushes the button
  to the right of it, so it shares rather than takes over. But a band hook that
  returns its own tree *without* calling `next(e)` ends the chain, and every
  hook below it never runs. If the button does not appear, that is almost
  certainly why.

  Hook order follows the key order of `enabledPlugins` in `~/.claude/settings.json`.
  Move `restart-button@restart-button` to the top of that object to put it
  above a mod that ends the chain:

  ```json
  {
    "enabledPlugins": {
      "restart-button@restart-button": true,
      "some-other-mod@its-marketplace": true
    }
  }
  ```

  A known example is `token-weather`, whose `AbovePrompt` hook returns its band
  directly. Any well-behaved band mod below it is hidden, not just this one.

## Layout

```
.claude-plugin/plugin.json       the manifest
.claude-plugin/marketplace.json  so the repo can be installed from
hooks/hooks.json                 names the module
hooks/register.tsx               the band hook and the button
scripts/restart.ps1              the restart itself
```

## License

MIT. See [LICENSE](LICENSE).
