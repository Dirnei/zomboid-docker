#!/usr/bin/env python3
"""ZombiRadar — PZ mod voting & staging with Discord OAuth integration."""

import json
import re
import threading
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie
from pathlib import Path

from books import SKILL_BOOKS
from config import PORT, MOD_MANAGER_ADMINS, OAUTH_AUTHORIZE_URL
from state import load_state, save_state, sync_mods_txt
from steam import fetch_workshop_info
from discord import (
    discord_api, exchange_code, fetch_discord_user, post_mod_to_discord,
    get_all_discord_votes, make_session, SESSIONS, discord_user_cache,
)

HTML = (Path(__file__).parent / "template.html").read_text()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def get_session(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        token = cookie.get("session")
        if token and token.value in SESSIONS:
            return SESSIONS[token.value]
        return None

    def require_auth(self):
        session = self.get_session()
        if not session:
            self.send_json({"error": "unauthorized"}, 401)
        return session

    def send_json(self, data, code=200, headers=None):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_redirect(self, url, headers=None):
        self.send_response(302)
        self.send_header("Location", url)
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()

    def send_html(self):
        body = HTML.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, content_type):
        try:
            body = Path(path).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "public, max-age=86400")
            self.end_headers()
            self.wfile.write(body)
        except FileNotFoundError:
            self.send_response(404)
            self.end_headers()

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(length)) if length else {}

    # ── GET ──

    def do_GET(self):
        if self.path == "/logo.png":
            self.send_file("/app/logo.png", "image/png")
            return

        if self.path == "/api/login":
            self.send_redirect(OAUTH_AUTHORIZE_URL)

        elif self.path.startswith("/api/callback"):
            self._handle_oauth_callback()

        elif self.path == "/api/logout":
            cookie = SimpleCookie(self.headers.get("Cookie", ""))
            token = cookie.get("session")
            if token and token.value in SESSIONS:
                del SESSIONS[token.value]
            self.send_redirect("/", headers={
                "Set-Cookie": "session=; Path=/; HttpOnly; Max-Age=0",
            })

        elif self.path == "/api/session":
            session = self.get_session()
            if session:
                self.send_json({
                    "ok": True,
                    "username": session["username"],
                    "role": session["role"],
                    "avatar_url": session.get("avatar_url"),
                })
            else:
                self.send_json({"error": "no session"}, 401)

        elif self.path == "/api/mods":
            session = self.require_auth()
            if not session:
                return
            state = load_state()
            self.send_json(state["mods"])

        elif self.path.startswith("/api/discord-votes"):
            session = self.require_auth()
            if not session:
                return
            params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            force = "1" in params.get("force", []) and session["role"] == "admin"
            state = load_state()
            all_votes = get_all_discord_votes(state, force=force)
            uid_to_name = {}
            for uid, u in state.get("users", {}).items():
                uid_to_name[uid] = u["username"]
            for uid, cached in discord_user_cache.items():
                uid_to_name.setdefault(uid, cached.get("username"))
            result = {}
            for mod in state["mods"]:
                msg_id = mod.get("discord_msg_id")
                if msg_id:
                    dv = all_votes.get(msg_id, {})
                    web_votes = mod.get("votes", {})
                    discord_names = {uid_to_name.get(uid) for uid in dv if uid_to_name.get(uid)}
                    deduped_ups = sum(1 for uid, v in dv.items() if v > 0)
                    deduped_downs = sum(1 for uid, v in dv.items() if v < 0)
                    result[mod["workshop_id"]] = {
                        "voted": session["discord_id"] in dv,
                        "ups": deduped_ups,
                        "downs": deduped_downs,
                        "overlap": list(discord_names & set(web_votes.keys())),
                    }
            self.send_json(result)

        elif self.path == "/api/users":
            session = self.require_auth()
            if not session or session["role"] != "admin":
                self.send_json({"error": "admin only"}, 403)
                return
            state = load_state()
            all_discord = get_all_discord_votes(state)
            suggested_mods = [m for m in state["mods"] if m["status"] == "suggested"]
            known_uids = set(state.get("users", {}).keys())
            all_discord_uids = set()
            for dv in all_discord.values():
                all_discord_uids.update(dv.keys())
            all_uids = known_uids | all_discord_uids
            users = []
            for uid in all_uids:
                u = state.get("users", {}).get(uid)
                if u:
                    username = u["username"]
                    avatar_url = u.get("avatar_url")
                    last_login = u.get("last_login", "?")
                    banned = u.get("banned", False)
                else:
                    cached = discord_user_cache.get(uid, {})
                    username = cached.get("username", f"Discord #{uid[:6]}")
                    avatar_url = cached.get("avatar_url")
                    last_login = "nie"
                    banned = False
                voted_on = 0
                for mod in suggested_mods:
                    web_voted = username in mod.get("votes", {})
                    dv = all_discord.get(mod.get("discord_msg_id"), {})
                    discord_voted = uid in dv
                    if web_voted or discord_voted:
                        voted_on += 1
                users.append({
                    "discord_id": uid,
                    "username": username,
                    "avatar_url": avatar_url,
                    "last_login": last_login,
                    "banned": banned,
                    "is_admin": uid in MOD_MANAGER_ADMINS,
                    "votes_cast": voted_on,
                    "votes_pending": len(suggested_mods) - voted_on,
                })
            self.send_json(users)

        elif self.path.startswith("/api/lookup/"):
            if not self.require_auth():
                return
            wid = self.path.split("/")[-1]
            info = fetch_workshop_info(wid)
            state = load_state()
            for mod in state["mods"]:
                if mod["workshop_id"] == wid:
                    changed = False
                    for key in ("title", "image", "description", "mod_id"):
                        if info.get(key) and not mod.get(key):
                            mod[key] = info[key]
                            changed = True
                    if changed:
                        save_state(state)
                    break
            self.send_json({"workshop_id": wid, **info})

        elif self.path == "/api/books":
            if not self.require_auth():
                return
            state = load_state()
            checked = state.get("books", {})
            result = []
            for group in SKILL_BOOKS:
                books = []
                for name in group["books"]:
                    entry = checked.get(name)
                    books.append({
                        "name": name,
                        "checked": entry is not None,
                        "checked_by": entry["by"] if entry else None,
                    })
                result.append({"skill": group["skill"], "books": books})
            self.send_json(result)

        else:
            self.send_html()

    # ── POST ──

    def do_POST(self):
        session = self.require_auth()
        if not session:
            return

        if self.path == "/api/mods":
            self._handle_suggest(session)
        elif re.match(r"/api/mods/\d+/vote$", self.path):
            self._handle_vote(session)
        elif re.match(r"/api/mods/\d+/stage$", self.path):
            self._handle_stage(session)
        elif re.match(r"/api/users/.+/ban$", self.path):
            self._handle_ban(session)
        elif self.path == "/api/books/toggle":
            data = self.read_body()
            name = data.get("name", "")
            state = load_state()
            books = state.setdefault("books", {})
            if name in books:
                del books[name]
            else:
                books[name] = {"by": session["username"]}
            save_state(state)
            self.send_json({"ok": True})
        else:
            self.send_json({"error": "not found"}, 404)

    # ── Handlers ──

    def _handle_oauth_callback(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = params.get("code", [None])[0]
        if not code:
            print(f"zombiradar: callback — no code in params: {params}")
            self.send_redirect("/")
            return
        print("zombiradar: callback — exchanging code...")
        token_data = exchange_code(code)
        if not token_data or "access_token" not in token_data:
            print(f"zombiradar: callback — token exchange failed: {token_data}")
            self.send_redirect("/?error=rate_limited")
            return
        print("zombiradar: callback — fetching discord user...")
        discord_user = fetch_discord_user(token_data["access_token"])
        if not discord_user or "id" not in discord_user:
            print(f"zombiradar: callback — user fetch failed: {discord_user}")
            self.send_redirect("/?error=login_failed")
            return
        print(f"zombiradar: callback — login success: {discord_user.get('username')} ({discord_user['id']})")
        session_token = make_session(discord_user)
        self.send_redirect("/", headers={
            "Set-Cookie": f"session={session_token}; Path=/; HttpOnly; SameSite=Lax",
        })

    def _handle_suggest(self, session):
        data = self.read_body()
        wid_match = re.search(r"id=(\d+)", data.get("workshop_id", ""))
        workshop_id = wid_match.group(1) if wid_match else data.get("workshop_id", "").strip()
        if not workshop_id or not workshop_id.isdigit():
            self.send_json({"error": "Ungültige Workshop ID"}, 400)
            return
        state = load_state()
        if any(m["workshop_id"] == workshop_id for m in state["mods"]):
            self.send_json({"error": "Mod bereits vorgeschlagen"}, 409)
            return
        info = fetch_workshop_info(workshop_id)
        mod = {
            "workshop_id": workshop_id,
            "title": info["title"],
            "image": info["image"],
            "suggested_by": session["username"],
            "votes": {},
            "status": "suggested",
            "discord_msg_id": None,
        }
        state["mods"].append(mod)
        save_state(state)
        post_mod_to_discord(state, mod, "suggested")
        self.send_json({"ok": True})

    def _handle_vote(self, session):
        idx = int(self.path.split("/")[3])
        state = load_state()
        if not (0 <= idx < len(state["mods"])):
            self.send_json({"error": "not found"}, 404)
            return
        user_entry = state.get("users", {}).get(session["discord_id"], {})
        if user_entry.get("banned"):
            self.send_json({"error": "Du wurdest vom Voting ausgeschlossen"}, 403)
            return
        mod = state["mods"][idx]
        data = self.read_body()
        value = data.get("value", 0)
        if value not in (1, -1):
            self.send_json({"error": "invalid vote"}, 400)
            return
        all_votes = get_all_discord_votes(state)
        dv = all_votes.get(mod.get("discord_msg_id"), {})
        if session["discord_id"] in dv:
            self.send_json({"error": "Bereits auf Discord abgestimmt"}, 409)
            return
        username = session["username"]
        current = mod.get("votes", {}).get(username, 0)
        if current == value:
            del mod["votes"][username]
        else:
            mod["votes"][username] = value
        save_state(state)
        self.send_json({"ok": True})
        threading.Thread(target=post_mod_to_discord, args=(state, mod, "voted"), daemon=True).start()

    def _handle_stage(self, session):
        if session["role"] != "admin":
            self.send_json({"error": "Nur Admins können Mods genehmigen"}, 403)
            return
        idx = int(self.path.split("/")[3])
        data = self.read_body()
        new_status = data.get("status")
        if new_status not in ("approved", "rejected", "deleted"):
            self.send_json({"error": "invalid status"}, 400)
            return
        state = load_state()
        if not (0 <= idx < len(state["mods"])):
            self.send_json({"error": "not found"}, 404)
            return
        mod = state["mods"][idx]
        if new_status == "deleted":
            thread_id = state.get("discord_thread_id")
            msg_id = mod.get("discord_msg_id")
            if thread_id and msg_id:
                discord_api("DELETE", f"/channels/{thread_id}/messages/{msg_id}")
            state["mods"].pop(idx)
        else:
            mod["status"] = new_status
            post_mod_to_discord(state, mod, new_status)
        save_state(state)
        sync_mods_txt(state)
        self.send_json({"ok": True})

    def _handle_ban(self, session):
        if session["role"] != "admin":
            self.send_json({"error": "admin only"}, 403)
            return
        uid = self.path.split("/")[3]
        if uid in MOD_MANAGER_ADMINS:
            self.send_json({"error": "Admins können nicht gesperrt werden"}, 403)
            return
        state = load_state()
        if uid not in state.get("users", {}):
            self.send_json({"error": "user not found"}, 404)
            return
        state["users"][uid]["banned"] = not state["users"][uid].get("banned", False)
        save_state(state)
        self.send_json({"ok": True})


if __name__ == "__main__":
    print(f"zombiradar: listening on port {PORT}")
    if MOD_MANAGER_ADMINS:
        print(f"zombiradar: admin discord IDs: {MOD_MANAGER_ADMINS}")
    else:
        print("zombiradar: WARNING — no MOD_MANAGER_ADMINS set, nobody can approve mods")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
