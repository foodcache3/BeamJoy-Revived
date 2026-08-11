# BeamJoy-Sandbox
<p align="center">
  <img src="./assets/cover.jpg" style="width: 49%; height: auto;" />
</p>
  
<p align="center">
This mod is a more refined version of the vanilla BeamMP (sandbox) experience. It allows for moderation and server administration in sandbox mode.<br/>
Since this mod provides a sandbox experience, it should be compatible with all of your previously installed mods (with minor exceptions).
</p>

<p align="center">
⚠️ This mod is not compatible with any other BeamJoy version. ⚠️<br/>
⚠️ Please ensure you removed any other version before running this mod. ⚠️
</p>

## About this fork

This is an actively developed, upgraded version of BeamJoy Sandbox, updated to run on
BeamNG.drive 0.39. On top of the sandbox/moderation feature set below, it's building toward a
set of racing- and gameplay-focused features.

### Planned features

Long-term roadmap — not scoped to any particular release, and not yet implemented. This section
will move into Features as things ship.

**Teleportation** (actively being worked on)

**Racing**
- Pit road / pit paddock options
- Reset/teleport to pits option
- Repair / refuel in pits, with configurable times for each
- Importer for old race configs to the new system
- Hotlapping system similar to Forza / SRP — a passive route with no visible checkpoints, driven
  naturally, as opposed to an active/visible race
- Per-race environment customization (time and weather planner)
- Per-race prop placement

**Drag Racing**
- Eighth / quarter / half / full mile options
- Usable drag strips
- Heads-up / bracket racing

**Gameplay**
- Simplified traffic agents / traffic group support
- New weather system customization
- Vehicle delivery together
- Trailer / cargo delivery
- Rideshare / taxi

## Features

- HTML windows and interfaces:
  - Provide a faster system than the IMGUI one implemented in the free version
  - Allow for persistent yet resizable/movable UI-Apps
  - Include a new custom Drag&Drop system
- Server-distributed traffic:
  - Allowed players can toggle it with menus, keybinds and radial menu
  - Customizable (max traffic vehicle, max vehicles per player, vehicles models)
  - Automatic lights with day & night cycle
  - Pursuits and arrests (random events when driving a police vehicle)
- Top screen menu bar with editable keybind (F4)
- Group system with permissions and configuration UI
- Players moderation tools (mute/kick/ban/temporary ban/remove vehicle(s)/...)
- Players database UI to manage offline players
- Built-in mods analyzer and modded maps detector
- In-game map switch with permission:
  - UI to edit maps labels
  - Each map can be toggled on or off to allow or prevent switching to it
- Customizable yet powerful welcome window
- Support for replay mode (players watching replays and their vehicles are not visible by others until they play again)
- Fixed and fully integrated vehicle selector (hide presets from disabled mods, filtered by permissions, fixed action buttons)
- Messages and labels internationalization
- Disabled multiplayer-conflicting features (desynced pause, force field)
- LocalStorage to keep personal data and settings between servers
- Contextual menu when right-clicking another vehicle (disabled while nodegrabbing or dragging view)
- Fast vehicle switch with a middle-click (mouse-wheel)
- Custom nametags system:
  - Different and customizable colors for active vehicles, idle vehicles and spectators (shared accross all beamjoy servers and versions)
  - Disabled for props
  - Disabled for trailers when the owner's vehicle is attached to it
- Server commands (`help` or `bj help` for the complete list)
- Whitelist with an UI configuration panel
- HUD UI App (icons + broadcast with colors)
- Safe zones (zones without collisions):
  - When a vehicle is exiting a safe zone, it stays a ghost until not colliding with another vehicle anymore (prevents vehicles merging)
- Synced pause and simulation speed:
  - Editable by staff members
  - Is triggered by game bindings (default : `J`=pause, `Alt`+`Up`/`Down`=toggle, `Alt`+`Left`/`Right`=presets swap)
  - Simulation speed will fallback to default (x1) if all staff members leave
- Time of day and gravity synced:
  - Can be toggle on/off
  - Editable by staff members
  - Can be edited via UI, menus and radial menu
  - Gravity will resets to default (Earth) if all staff members leave
  - Customizable day/night cycle duration
  - Optional night brightness multiplier
- Trailers and Props spawning permissions
- Vehicle models blacklist
- Toggle allowing players mods:
  - Those mods are client-side only, similar to vanilla BeamMP
  - With advanced mods features, now players:
    -  can activate a single mod (if the server configurations allows it) instead of enabling all their collection.
    -  can download a mod and it will be disabled automatically if the server doesn't allow it.
    -  cannot disable nor remove server served mods.
    -  can disable a specific mod (not a server served one) and it will impact their own vehicles (if the mod was a vehicle one).
- Server core settings UI
- Custom chat (show staff tag, with colors)
- Chat commands (permissionned, easy-to-add system):
  - `/help` : Shows the complete list of available commands
  - `/pm <player_name> <message>` : Sends a private message to someone (a copy is also send to staff members for safety purposes)
- DiscordHook mod chat events integration
- Toggleable chat broadcasts:
  - Configurable delay between messages
  - Messages can be translated

## How to install

Just like the free version, you can download the latest release [HERE](https://github.com/foodcache3/BeamJoy-sandbox/releases/latest) and extract it inside your server's `Resources` folder.<br/>
No update should never replace server nor players data.

## Support Samael

<p align="center">
  <a target="_blank" href="https://coff.ee/tontonsamael" alt="Buy me a coffee">
    <img src="https://github.com/my-name-is-samael/BeamJoy/blob/main/assets/buymeacoffee.png?raw=" width="250" alt="Buy me a coffee" />
  </a>
</p>
