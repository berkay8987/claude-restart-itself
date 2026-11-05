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
2. The surviving helper calls `CloseMainWindow()` on every Claude process, so
   the app saves its state, and waits up to 8 seconds.
3. Anything still up is force-killed, and it waits for the process table to
   actually clear.
4. After a short pause for the package's single-instance lock, it opens
   `claude://code/continue?session=last`.
5. If the app is not back within 10 seconds it retries through `explorer.exe`,
   and then through `shell:AppsFolder`.

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
- **Only one hook may draw the band.** This one draws whatever the engine and
  other plugins put there and pushes the button to the right of it, so it
  shares rather than takes over — but if another plugin's band hook runs above
  this one and returns its own tree, the button will not appear.

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
