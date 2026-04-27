#!/usr/bin/env python3
"""ZombiRadar — PZ mod voting & staging with Discord OAuth integration."""

import json
import re
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
from http.cookies import SimpleCookie
from pathlib import Path

from config import PORT, MOD_MANAGER_ADMINS, OAUTH_AUTHORIZE_URL
from state import load_state, save_state, sync_mods_txt
from steam import fetch_workshop_info
from discord import (
    discord_api, exchange_code, fetch_discord_user, post_mod_to_discord,
    get_all_discord_votes, make_session, SESSIONS,
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
            all_votes = get_all_discord_votes(state)
            mods = []
            for mod in state["mods"]:
                m = dict(mod)
                dv = all_votes.get(mod.get("discord_msg_id"), {})
                m["voted_on_discord"] = session["discord_id"] in dv
                m["discord_ups"] = sum(1 for v in dv.values() if v > 0)
                m["discord_downs"] = sum(1 for v in dv.values() if v < 0)
                mods.append(m)
            self.send_json(mods)

        elif self.path.startswith("/api/lookup/"):
            if not self.require_auth():
                return
            wid = self.path.split("/")[-1]
            info = fetch_workshop_info(wid)
            self.send_json({"workshop_id": wid, **info})

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
            self.send_redirect("/")
            return
        print("zombiradar: callback — fetching discord user...")
        discord_user = fetch_discord_user(token_data["access_token"])
        if not discord_user or "id" not in discord_user:
            print(f"zombiradar: callback — user fetch failed: {discord_user}")
            self.send_redirect("/")
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
        post_mod_to_discord(state, mod, "voted")
        self.send_json({"ok": True})

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


if __name__ == "__main__":
    print(f"zombiradar: listening on port {PORT}")
    if MOD_MANAGER_ADMINS:
        print(f"zombiradar: admin discord IDs: {MOD_MANAGER_ADMINS}")
    else:
        print("zombiradar: WARNING — no MOD_MANAGER_ADMINS set, nobody can approve mods")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
