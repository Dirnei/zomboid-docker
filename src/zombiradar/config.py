import os
import urllib.parse

PORT = int(os.environ.get("PORT", "8080"))
MODS_FILE = os.environ.get("MODS_FILE", "/data/mods.txt")
STATE_FILE = os.environ.get("STATE_FILE", "/data/state.json")

DISCORD_TOKEN = os.environ.get("DISCORD_TOKEN", "")
DISCORD_CHANNEL_ID = os.environ.get("DISCORD_CHANNEL_ID", "")
DISCORD_CLIENT_ID = os.environ.get("DISCORD_CLIENT_ID", "")
DISCORD_CLIENT_SECRET = os.environ.get("DISCORD_CLIENT_SECRET", "")
MOD_MANAGER_URL = os.environ.get("MOD_MANAGER_URL", "http://localhost:8080").rstrip("/")
MOD_MANAGER_ADMINS = set(
    a.strip() for a in os.environ.get("MOD_MANAGER_ADMINS", "").split(",") if a.strip()
)

OAUTH_REDIRECT_URI = f"{MOD_MANAGER_URL}/api/callback"
OAUTH_AUTHORIZE_URL = (
    f"https://discord.com/oauth2/authorize?client_id={DISCORD_CLIENT_ID}"
    f"&redirect_uri={urllib.parse.quote(OAUTH_REDIRECT_URI)}"
    f"&response_type=code&scope=identify"
)

CACHE_TTL = 300
BOARD_STALE_DAYS = int(os.environ.get("BOARD_STALE_DAYS", "7"))
SANDBOX_FILE = os.environ.get("SANDBOX_FILE", "/config/SandboxVars.lua")
OVERRIDES_FILE = os.environ.get("OVERRIDES_FILE", "/config/overrides.ini")
