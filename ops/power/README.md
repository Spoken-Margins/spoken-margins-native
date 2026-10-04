# Keep awake

The MacBook does the project's builds and lane runs, and it sleeps 10 minutes after the last keypress on battery, or as soon as the lid closes. A build or lane job caught by that sleep is lost (#762). This folder keeps the Mac awake while there's work, using [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704), and lets it sleep normally otherwise.

- `amph`: a small command-line handle on Amphetamine, written in AppleScript. Agents and scripts use it.
- `sm_keep_awake.py`: a launchd job that runs every minute and decides whether the Mac should stay awake.

## What the job does

Every minute it looks for work:

1. **A build or test is running**: `xcodebuild`, `swift-build`, `swift-test`, `swift-frontend`, `xctest`, or a lane job's `Runner.Worker`. This counts even without a network, so a local build can finish.
2. **An agent is working**: a Claude Code or Codex session wrote to its transcript in the last 10 minutes, and the Mac has a network (Wi-Fi or otherwise). An open Claude app, or a session waiting for you, doesn't count. Claude Code keeps a process for every open session, idle or not, so "Claude is running" would mean "always awake".

When there's work, it asks Amphetamine for a 20-minute session with `amph ensure 20 --lid`. That renews the session when less than half is left. When the work stops, the session runs out within 20 minutes and the Mac goes back to its usual sleep settings. The display may sleep during these sessions; the screen is the biggest drain on battery.

On battery at **10% or below** it stops asking. Amphetamine's own low-battery setting ends any session at the same level, so the two agree.

It never ends or shortens a session. If you started one yourself (until stopped, until a time, while an app runs, or from a Trigger), it leaves it alone, except that `--lid` turns on lid-closed running for it.

Changes in its decision, and each session it starts, go to `~/SpokenMarginsOps/keep-awake/log.txt`.

**Heat.** With `--lid`, the Mac keeps compiling with the lid shut, on battery too. That's fine on a desk. In a bag it can get hot. Take the `--lid` line out of the plist if that's a worry.

## Amphetamine settings

Already set on this Mac: end sessions when the battery falls below 10%, and ignore the battery while on power. Keep those.

Change these in Amphetamine's Settings:

1. **Turn off the sound for sessions starting and ending** (in the Notifications settings). Otherwise you hear a chime about every 10 minutes while the job renews sessions.
2. **Dismiss the lid warning for good.** In Sessions, turn **Allow system to sleep when display is closed** off, and in the warning that appears choose **Do not show this message again**. Then turn it back on. Until you do this, the job's lid request can stop on that warning.
3. **Leave Triggers off.** The job does their work, and Triggers can't see agent activity.
4. **End a "while Claude is running" session** if one is going. The Claude app is always open, so it holds the Mac awake until the battery hits 10%. The job is the narrower version of the same idea.

## Leaving the Mac for a fixed time

When you know the Mac will be on power with a network for a while, and want to close the lid and walk away, hold it for that long:

```zsh
~/Documents/GitHub/spoken-margins-native/ops/power/amph hold 41h
```

It stays awake for exactly that long, lid closed included, whether or not agents are busy, so a crash or an agent stopping to wait doesn't let it sleep. The display sleeps. It replaces whatever session was running, and the job leaves it alone. `amph status` shows the seconds left; `amph stop` ends it early. On battery, Amphetamine still ends it at 10%. Lane runners keep working with the lid closed only once the lane power guard counts Amphetamine (#787).

## Using `amph`

```zsh
ops/power/amph status
```

```zsh
ops/power/amph ensure 90 --lid
```

| Command | What it does |
|---|---|
| `amph status` | JSON: `active`, `remaining_seconds`, `kind` (`none`, `timed`, `until_stopped`, `trigger`, `app_or_time`), `lid_awake`, `display_sleep_allowed`, `triggers_enabled`. |
| `amph hold <41h\|90m\|1h30m>` | Stays awake exactly that long, lid closed included, busy or not. Replaces any session. Cole's command for walking away. |
| `amph ensure <min> [--lid] [--screen-on]` | Keeps the Mac awake for about `<min>` more minutes. Never shortens or replaces another session. This is the one agents use, for example before a long build. |
| `amph start <min> [--lid] [--screen-on]` | Replaces whatever session is running with a new one. `0` means until stopped. |
| `amph stop` | Ends the current session. Cole's call, not an agent's: it ends other people's holds too. |
| `amph lid on\|off` | Keep running with the lid closed (Amphetamine's closed-display mode). |
| `amph display-sleep allow\|prevent` | Whether the screen may sleep during the session. |
| `amph triggers on\|off` | Turn Amphetamine's Triggers on or off. |

Errors go to stderr with a non-zero exit. Calling `amph` opens Amphetamine if it isn't running, except `status`, which reports `{"running":false}`.

## Check what it would do

```zsh
python3 ~/Documents/GitHub/spoken-margins-native/ops/power/sm_keep_awake.py --dry-run
```

It prints the battery, network, builds and agent activity it sees, and its decision. It changes nothing.

## Install

The PR doesn't install it. To turn it on:

```zsh
mkdir -p ~/SpokenMarginsOps/keep-awake
```

```zsh
cp ~/Documents/GitHub/spoken-margins-native/ops/power/com.spokenmargins.keep-awake.plist ~/Library/LaunchAgents/
```

```zsh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.spokenmargins.keep-awake.plist
```

The first time it talks to Amphetamine, macOS asks whether `python3` (or `osascript`) may control Amphetamine. Choose **Allow**. If you miss it, turn it on in System Settings, Privacy & Security, Automation.

To turn it off:

```zsh
launchctl bootout gui/$(id -u)/com.spokenmargins.keep-awake
```

```zsh
rm ~/Library/LaunchAgents/com.spokenmargins.keep-awake.plist
```

## With the lane power guard

The lane power guard (`ops/lane/sm_lane_power_guard.py`, #763) pauses idle lane runners on battery or with the lid closed, because back then nothing could keep the Mac awake. With this job installed, it should count an Amphetamine session above 10% battery (with lid-closed running, when the lid is shut) as able to stay awake. Until it does, lane jobs still wait for the charger.

## Tests

```zsh
python3 -m unittest discover -s ops/power
```
