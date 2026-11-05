import type { Register } from 'claude-code'

// Spawned by argv with no shell, so PATH is not relied on. Forward slashes
// throughout: Windows accepts them, and they survive every layer unescaped.
const PWSH = 'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'

export const register: Register = on => {
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // Whatever the engine and the other plugins put in the band.
    const below = await next(e)

    // A survey owns the whole band; stay out of its way.
    if (e.props.hasSurvey) {
      return below
    }

    const { Box, Button } = $.ui.resolve(e)

    const onPress = async () => {
      const argv = [
        PWSH,
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        `${$.plugin.root}/scripts/restart.ps1`,
        '-Session',
        'last',
      ]

      try {
        // The helper re-launches itself detached and then does the work, so it
        // outlives this process; this returns as soon as it has handed off.
        const out = await $.process.run(argv, { timeoutMs: 20000 })

        if (out.exitCode !== 0) {
          $.ui.toast(`restart: exit=${out.exitCode} ${out.stderr.slice(0, 120)}`)

          return
        }

        $.ui.toast('Restarting Claude…')
      } catch (err) {
        $.ui.toast(`restart: FAILED ${String(err).slice(0, 140)}`)
      }
    }

    return (
      <Box>
        <Box flexGrow={1}>{below}</Box>
        <Button key="restart" label="⟳" onPress={onPress} />
      </Box>
    )
  })
}
