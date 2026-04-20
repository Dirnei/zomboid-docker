# Project Zomboid Dedicated Server

Docker Compose setup for a noob-friendly Project Zomboid multiplayer server with automated backups.

## Quick Start

1. Copy and edit the environment file:

   ```bash
   cp .env.example .env
   # Edit .env — at minimum change SERVER_PASSWORD and ADMIN_PASSWORD
   ```

2. Start the server:

   ```bash
   docker compose up -d
   ```

3. First boot takes a few minutes (downloads SteamCMD + game files, ~3-4 GB).

4. Connect in-game: **Host/IP** > your server's IP, **Port** > `16261`.

## Project Structure

```
.
├── docker-compose.yml          # Game server + backup sidecar
├── .env                        # Server configuration (gitignored)
├── .env.example                # Template for .env
├── server-config/
│   ├── SandboxVars.lua         # Gameplay / sandbox settings
│   └── servertest.ini          # Server .ini overrides
└── backups/                    # Auto-created, stores backup archives
```

## Configuration

All server settings live in `.env`:

| Variable | Default | Description |
|---|---|---|
| `SERVER_NAME` | `ZomboidServer` | Server name shown in browser |
| `SERVER_PASSWORD` | `changeme` | Password to join |
| `ADMIN_PASSWORD` | `adminchangeme` | In-game admin password |
| `MAX_PLAYERS` | `8` | Max concurrent players |
| `SERVER_MEMORY` | `4096m` | Java heap size |
| `MOD_IDS` | *(empty)* | Comma-separated mod IDs |
| `MOD_WORKSHOP_IDS` | *(empty)* | Comma-separated Workshop IDs |
| `GAME_PORT` | `16261` | Main game port (UDP) |
| `DIRECT_PORT` | `16262` | Direct connection port (UDP) |
| `RCON_PORT` | `27015` | Remote console port |
| `RCON_PASSWORD` | `rconchangeme` | RCON password |
| `BACKUP_CRON` | `0 */6 * * *` | Backup schedule (every 6 hours) |
| `BACKUP_RETENTION_DAYS` | `7` | Days to keep old backups |
| `TZ` | `Europe/Berlin` | Container timezone |

## Noob-Friendly Sandbox Settings

The sandbox config in `server-config/SandboxVars.lua` is tuned for new players:

| Setting | Value | Why |
|---|---|---|
| Zombie transmission | **None** | No zombie infection from bites — learn combat without permadeath |
| Zombie speed | Shambler | No sprinters |
| Zombie strength/toughness | Weak / Fragile | Easier fights |
| XP multiplier | 3x | Faster skill progression |
| Loot | Abundant | More supplies to find |
| Utilities shutoff | 1-6 months | Long grace period with power and water |
| Start month | July | Warm weather, no freezing |
| Map | Always revealed | No need to find map items |
| Reading speed | 0.1 min/page | Books take seconds, not hours |
| PVP | Off | No friendly fire |
| Day length | 1 hour | Enough daylight to get things done |

### Graduating to Harder Settings

Once your group is comfortable, crank these up in order:

1. Set `Transmission = 2` (Saliva Only) — bites matter again
2. Drop `XPMultiplier` to `2.0`
3. Set loot values back to `3` (Normal)
4. Set `ZombieStrength = 2` and `ZombieToughness = 2` (Normal)

## Backups

A lightweight Alpine sidecar container runs on a cron schedule (default: every 6 hours).

- Backups are saved to `./backups/` as timestamped `.tar.gz` archives
- Old backups are automatically deleted after `BACKUP_RETENTION_DAYS` (default: 7)

### Manual Backup

```bash
docker exec zomboid-backup sh -c \
  'tar czf /data/backups/zomboid-backup-manual-$(date +%Y%m%d-%H%M%S).tar.gz -C /data/saves .'
```

### Restore from Backup

```bash
docker compose down
# Extract backup into the server-saves volume
docker run --rm -v zomboid_server-saves:/data -v ./backups:/backups alpine \
  sh -c 'rm -rf /data/* && tar xzf /backups/<backup-file>.tar.gz -C /data'
docker compose up -d
```

## Adding Mods

1. Find the mod on the [Steam Workshop](https://steamcommunity.com/app/108600/workshop/).
2. Get the **Workshop ID** from the URL (e.g., `steamcommunity.com/sharedfiles/filedetails/?id=2313387159`).
3. Get the **Mod ID** from the mod's description (usually listed by the author).
4. Add both to `.env`:

   ```env
   MOD_IDS=MyModID,AnotherModID
   MOD_WORKSHOP_IDS=2313387159,2392709985
   ```

5. Restart: `docker compose restart zomboid`

## Ports

Make sure these ports are forwarded on your router / firewall:

| Port | Protocol | Purpose |
|---|---|---|
| 16261 | UDP | Game traffic |
| 16262 | UDP | Direct connection |
| 27015 | TCP | RCON (optional, only if using remote admin) |

## Useful Commands

```bash
# View server logs
docker compose logs -f zomboid

# Stop the server gracefully
docker compose down

# Restart after config changes
docker compose restart zomboid

# Open server console
docker attach zomboid-server
# (Ctrl+P, Ctrl+Q to detach without stopping)
```
