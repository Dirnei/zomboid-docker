import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from hashlib import sha256

from config import (
    DISCORD_TOKEN, DISCORD_CHANNEL_ID, DISCORD_CLIENT_ID,
    DISCORD_CLIENT_SECRET, OAUTH_REDIRECT_URI, MOD_MANAGER_ADMINS, CACHE_TTL,
)
from state import save_state

SESSIONS = {}

_discord_votes_mem = {}
_discord_votes_mem_time = 0

_api_lock = threading.Lock()
_api_last_call = 0
_api_blocked_until = 0
API_COOLDOWN = 600


def discord_api(method, path, body=None, token=None, content_type="application/json", skip_cooldown=False):
    global _api_last_call, _api_blocked_until
    now = time.time()
    if not skip_cooldown and now < _api_blocked_until:
        remaining = int(_api_blocked_until - now)
        print(f"zombiradar: discord blocked for {remaining}s, skipping {method} {path}")
        return None
    url = f"https://discord.com/api/v10{path}"
    if content_type == "application/json":
        data = json.dumps(body).encode() if body else None
    else:
        data = urllib.parse.urlencode(body).encode() if body else None
    with _api_lock:
        wait = 0.5 - (time.time() - _api_last_call)
        if wait > 0:
            time.sleep(wait)
        _api_last_call = time.time()
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bot {DISCORD_TOKEN}" if not token else f"Bearer {token}",
        "Content-Type": content_type,
        "User-Agent": "ZombiRadar/1.0",
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = resp.read().decode()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        if e.code == 429:
            _api_blocked_until = time.time() + API_COOLDOWN
            print(f"zombiradar: rate limited! blocking all Discord calls for {API_COOLDOWN}s")
            return None
        print(f"zombiradar: discord api error: {e}")
        return None
    except Exception as e:
        print(f"zombiradar: discord api error: {e}")
        return None


def exchange_code(code):
    data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": OAUTH_REDIRECT_URI,
        "client_id": DISCORD_CLIENT_ID,
        "client_secret": DISCORD_CLIENT_SECRET,
    }).encode()
    req = urllib.request.Request(
        "https://discord.com/api/v10/oauth2/token",
        data=data,
        method="POST",
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "ZombiRadar/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"zombiradar: oauth token exchange error: {e.code} {body}")
        return None
    except Exception as e:
        print(f"zombiradar: oauth token exchange error: {e}")
        return None


def fetch_discord_user(access_token):
    return discord_api("GET", "/users/@me", token=access_token, skip_cooldown=True)


def ensure_discord_thread(state):
    if state.get("discord_thread_id"):
        return state["discord_thread_id"]
    if not DISCORD_TOKEN or not DISCORD_CHANNEL_ID:
        return None
    result = discord_api("POST", f"/channels/{DISCORD_CHANNEL_ID}/threads", {
        "name": "Mod-Vorschläge",
        "type": 11,
        "auto_archive_duration": 10080,
    })
    if result and "id" in result:
        state["discord_thread_id"] = result["id"]
        save_state(state)
        return result["id"]
    return None


def ensure_thread(state, state_key, thread_name):
    """Create or reuse a named Discord thread. Thread ID stored in state[state_key]."""
    if state.get(state_key):
        return state[state_key]
    if not DISCORD_TOKEN or not DISCORD_CHANNEL_ID:
        return None
    result = discord_api("POST", f"/channels/{DISCORD_CHANNEL_ID}/threads", {
        "name": thread_name,
        "type": 11,
        "auto_archive_duration": 10080,
    })
    if result and "id" in result:
        state[state_key] = result["id"]
        save_state(state)
        return result["id"]
    return None


def post_to_thread(state, state_key, thread_name, content, msg_id_holder=None, msg_id_key="discord_msg_id"):
    """Post or edit a message in a named thread."""
    thread_id = ensure_thread(state, state_key, thread_name)
    if not thread_id:
        return
    if msg_id_holder and msg_id_holder.get(msg_id_key):
        discord_api("PATCH", f"/channels/{thread_id}/messages/{msg_id_holder[msg_id_key]}", {"content": content})
    else:
        result = discord_api("POST", f"/channels/{thread_id}/messages", {"content": content})
        if result and "id" in result and msg_id_holder is not None:
            msg_id_holder[msg_id_key] = result["id"]
            save_state(state)


def post_mod_to_discord(state, mod, action="suggested"):
    thread_id = ensure_discord_thread(state)
    if not thread_id:
        return
    title = mod.get("title") or mod["workshop_id"]
    url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={mod['workshop_id']}"
    votes = mod.get("votes", {})
    if isinstance(votes, dict):
        ups = sum(1 for v in votes.values() if v > 0)
        downs = sum(1 for v in votes.values() if v < 0)
        score = ups - downs
        vote_count = f"+{score}" if score > 0 else str(score)
        voters = f"\U0001F44D {ups} \U0001F44E {downs}"
    else:
        vote_count = len(votes)
        voters = ", ".join(votes) if votes else "keine"

    messages = {
        "suggested": (
            f":new: **Neuer Mod-Vorschlag** von **{mod.get('suggested_by', '?')}**\n"
            f"**{title}**\n{url}\nStimmen: {vote_count} ({voters})"
        ),
        "approved": (
            f":white_check_mark: **Mod genehmigt!**\n"
            f"**{title}**\n{url}\nStimmen: {vote_count} ({voters})\n"
            f"*Wird beim nächsten Server-Neustart geladen.*"
        ),
        "rejected": (
            f":x: **Mod abgelehnt**\n~~{title}~~\n{url}\nStimmen: {vote_count} ({voters})"
        ),
        "voted": (
            f":thumbsup: **Mod-Vorschlag**\n"
            f"**{title}**\n{url}\nStimmen: {vote_count} ({voters})"
        ),
    }
    content = messages.get(action)
    if not content:
        return

    msg_id = mod.get("discord_msg_id")
    if msg_id:
        discord_api("PATCH", f"/channels/{thread_id}/messages/{msg_id}", {"content": content})
    else:
        result = discord_api("POST", f"/channels/{thread_id}/messages", {"content": content})
        if result and "id" in result:
            mod["discord_msg_id"] = result["id"]
            save_state(state)
            if action == "suggested":
                r1 = discord_api("PUT", f"/channels/{thread_id}/messages/{result['id']}/reactions/%F0%9F%91%8D/%40me")
                print(f"zombiradar: seed 👍: {r1}")
                time.sleep(0.5)
                r2 = discord_api("PUT", f"/channels/{thread_id}/messages/{result['id']}/reactions/%F0%9F%91%8E/%40me")
                print(f"zombiradar: seed 👎: {r2}")


discord_user_cache = {}

def fetch_discord_votes(thread_id, msg_id):
    if not thread_id or not msg_id:
        return {}
    bot_id = DISCORD_CLIENT_ID
    ups = discord_api("GET", f"/channels/{thread_id}/messages/{msg_id}/reactions/%F0%9F%91%8D")
    for u in (ups or []):
        if u["id"] != bot_id:
            discord_user_cache[u["id"]] = {
                "username": u.get("global_name") or u["username"],
                "avatar_url": f"https://cdn.discordapp.com/avatars/{u['id']}/{u['avatar']}.png" if u.get("avatar") else None,
            }
    up_ids = {u["id"] for u in (ups or []) if u["id"] != bot_id}
    downs = discord_api("GET", f"/channels/{thread_id}/messages/{msg_id}/reactions/%F0%9F%91%8E")
    for u in (downs or []):
        if u["id"] != bot_id:
            discord_user_cache[u["id"]] = {
                "username": u.get("global_name") or u["username"],
                "avatar_url": f"https://cdn.discordapp.com/avatars/{u['id']}/{u['avatar']}.png" if u.get("avatar") else None,
            }
    down_ids = {u["id"] for u in (downs or []) if u["id"] != bot_id}
    both = up_ids & down_ids
    votes = {}
    for uid in up_ids - both:
        votes[uid] = 1
    for uid in down_ids - both:
        votes[uid] = -1
    for uid in both:
        votes[uid] = 0
    return votes


_refresh_lock = threading.Lock()
_refreshing = False


def _refresh_discord_votes(state):
    global _discord_votes_mem, _discord_votes_mem_time, _refreshing
    thread_id = state.get("discord_thread_id")
    if not thread_id:
        _refreshing = False
        return
    msg_ids = [
        mod.get("discord_msg_id")
        for mod in state["mods"]
        if mod.get("discord_msg_id")
    ]
    if not msg_ids:
        _refreshing = False
        return
    result = {}
    for mid in msg_ids:
        result[mid] = fetch_discord_votes(thread_id, mid)
    _discord_votes_mem = result
    _discord_votes_mem_time = time.time()
    from state import load_state as _load, save_state as _save
    fresh = _load()
    fresh["discord_votes_cache"] = {k: dict(v) for k, v in result.items()}
    fresh["discord_votes_cached_at"] = _discord_votes_mem_time
    _save(fresh)
    _refreshing = False
    print(f"zombiradar: discord votes refreshed ({len(msg_ids)} mods)")


def get_all_discord_votes(state, force=False):
    global _discord_votes_mem, _discord_votes_mem_time, _refreshing
    now = time.time()
    # 1. Fresh in-memory cache — return immediately
    if not force and now - _discord_votes_mem_time < CACHE_TTL:
        return _discord_votes_mem
    # 2. Load from state.json cache (stale is fine, better than empty)
    cached = state.get("discord_votes_cache", {})
    cached_at = state.get("discord_votes_cached_at", 0)
    if not _discord_votes_mem_time and cached:
        _discord_votes_mem = {k: {uid: v for uid, v in votes.items()} for k, votes in cached.items()}
    # 3. State.json cache still fresh — use it
    if not force and now - cached_at < CACHE_TTL:
        _discord_votes_mem = {k: {uid: v for uid, v in votes.items()} for k, votes in cached.items()}
        _discord_votes_mem_time = now
        return _discord_votes_mem
    # 4. Force refresh — block and fetch
    if force:
        _refresh_discord_votes(state)
        return _discord_votes_mem
    # 5. Background refresh — return stale data now, update later
    if not _refreshing:
        _refreshing = True
        threading.Thread(target=_refresh_discord_votes, args=(state,), daemon=True).start()
    return _discord_votes_mem


def make_session(discord_user):
    from state import load_state, save_state
    user_id = discord_user["id"]
    username = discord_user.get("global_name") or discord_user["username"]
    avatar = discord_user.get("avatar")
    avatar_url = (
        f"https://cdn.discordapp.com/avatars/{user_id}/{avatar}.png"
        if avatar else None
    )
    role = "admin" if user_id in MOD_MANAGER_ADMINS else "user"
    token = sha256(f"{user_id}{time.time()}{os.urandom(16).hex()}".encode()).hexdigest()[:32]
    SESSIONS[token] = {
        "discord_id": user_id,
        "username": username,
        "avatar_url": avatar_url,
        "role": role,
    }
    state = load_state()
    state["users"][user_id] = {
        "username": username,
        "avatar_url": avatar_url,
        "last_login": time.strftime("%Y-%m-%d %H:%M"),
        "banned": state.get("users", {}).get(user_id, {}).get("banned", False),
    }
    save_state(state)
    return token
