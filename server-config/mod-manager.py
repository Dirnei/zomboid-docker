#!/usr/bin/env python3
"""Tiny mod manager web UI for Project Zomboid. Zero external dependencies."""

import base64
import json
import os
import re
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

PASSWORD = os.environ.get("MOD_MANAGER_PASSWORD", "admin")
MODS_FILE = os.environ.get("MODS_FILE", "/data/mods.txt")
PORT = int(os.environ.get("PORT", "8080"))


def read_mods():
    mods = []
    if not os.path.exists(MODS_FILE):
        return mods
    with open(MODS_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            m = re.search(r"id=(\d+)", line)
            if m:
                wid = m.group(1)
            else:
                wid = line.split()[0]
            parts = line.split()
            mid = parts[1] if len(parts) > 1 else ""
            mods.append({"workshop_id": wid, "mod_id": mid})
    return mods


def write_mods(mods):
    with open(MODS_FILE, "w") as f:
        f.write("# Steam Workshop Mods — one per line\n")
        f.write("# Format: <workshop-id> <mod-id>\n")
        f.write("#\n")
        for mod in mods:
            f.write(f"{mod['workshop_id']} {mod['mod_id']}\n")


def fetch_workshop_title(workshop_id):
    try:
        url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={workshop_id}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        m = re.search(r'<div class="workshopItemTitle">([^<]+)</div>', html)
        return m.group(1).strip() if m else None
    except Exception:
        return None


HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PZ Mod Manager</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #1a1a2e; color: #e0e0e0; min-height: 100vh; padding: 2rem; }
  .container { max-width: 800px; margin: 0 auto; }
  h1 { color: #e94560; margin-bottom: 0.5rem; }
  .subtitle { color: #888; margin-bottom: 2rem; }
  .card { background: #16213e; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; }
  .card h2 { color: #e94560; margin-bottom: 1rem; font-size: 1.1rem; }
  .form-row { display: flex; gap: 0.75rem; margin-bottom: 0.75rem; flex-wrap: wrap; }
  input[type="text"] { flex: 1; min-width: 200px; padding: 0.6rem 0.8rem; border: 1px solid #333;
                        border-radius: 4px; background: #0f3460; color: #e0e0e0; font-size: 0.95rem; }
  input[type="text"]::placeholder { color: #666; }
  input[type="text"]:focus { outline: none; border-color: #e94560; }
  button { padding: 0.6rem 1.2rem; border: none; border-radius: 4px; cursor: pointer;
           font-size: 0.95rem; font-weight: 500; transition: opacity 0.2s; }
  button:hover { opacity: 0.85; }
  .btn-add { background: #e94560; color: white; }
  .btn-remove { background: #333; color: #e94560; padding: 0.4rem 0.8rem; font-size: 0.85rem; }
  .btn-lookup { background: #0f3460; color: #e0e0e0; border: 1px solid #333; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; padding: 0.6rem; color: #888; border-bottom: 1px solid #333; font-size: 0.85rem; }
  td { padding: 0.6rem; border-bottom: 1px solid #222; }
  .empty { color: #666; font-style: italic; padding: 1rem; }
  .workshop-link { color: #5ba4e6; text-decoration: none; }
  .workshop-link:hover { text-decoration: underline; }
  .title-cell { color: #ccc; }
  .notice { background: #0f3460; border-left: 3px solid #e94560; padding: 0.8rem 1rem;
            border-radius: 0 4px 4px 0; margin-bottom: 1.5rem; font-size: 0.9rem; color: #aaa; }
  .status { padding: 0.5rem; margin-top: 0.5rem; border-radius: 4px; font-size: 0.9rem; display: none; }
  .status.ok { display: block; background: #1a3a1a; color: #4caf50; }
  .status.err { display: block; background: #3a1a1a; color: #e94560; }
  .loading { color: #888; font-style: italic; }
</style>
</head>
<body>
<div class="container">
  <h1>PZ Mod Manager</h1>
  <p class="subtitle">Add or remove Steam Workshop mods. Changes take effect on server restart.</p>
  <div class="notice">Restart the Zomboid server after changing mods for them to take effect.</div>

  <div class="card">
    <h2>Add Mod</h2>
    <div class="form-row">
      <input type="text" id="workshop-id" placeholder="Workshop URL or ID">
      <button class="btn-lookup" onclick="lookup()">Lookup</button>
    </div>
    <div class="form-row">
      <input type="text" id="mod-id" placeholder="Mod ID (from workshop description)">
      <button class="btn-add" onclick="addMod()">Add Mod</button>
    </div>
    <div id="lookup-result"></div>
    <div id="add-status" class="status"></div>
  </div>

  <div class="card">
    <h2>Installed Mods</h2>
    <div id="mod-list"><span class="loading">Loading...</span></div>
  </div>
</div>

<script>
function extractId(input) {
  const m = input.match(/id=(\d+)/);
  return m ? m[1] : input.trim();
}

async function api(method, path, body) {
  const opts = { method, headers: { "Content-Type": "application/json" } };
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch(path, opts);
  return r.json();
}

async function loadMods() {
  const mods = await api("GET", "/api/mods");
  const el = document.getElementById("mod-list");
  if (!mods.length) {
    el.innerHTML = '<p class="empty">No mods installed</p>';
    return;
  }
  let html = "<table><tr><th>#</th><th>Workshop ID</th><th>Mod ID</th><th>Title</th><th></th></tr>";
  mods.forEach((m, i) => {
    const link = '<a class="workshop-link" href="https://steamcommunity.com/sharedfiles/filedetails/?id='
      + m.workshop_id + '" target="_blank">' + m.workshop_id + "</a>";
    html += "<tr><td>" + (i + 1) + "</td><td>" + link + "</td><td>" + (m.mod_id || "-")
      + '</td><td class="title-cell">' + (m.title || '<span class="loading">...</span>')
      + '</td><td><button class="btn-remove" onclick="removeMod(' + i + ')">Remove</button></td></tr>';
  });
  html += "</table>";
  el.innerHTML = html;
  // Fetch titles in background
  for (let i = 0; i < mods.length; i++) {
    if (!mods[i].title) {
      api("GET", "/api/lookup/" + mods[i].workshop_id).then(data => {
        if (data.title) {
          const cells = document.querySelectorAll("table tr")[i + 1]?.querySelectorAll("td");
          if (cells && cells[3]) cells[3].textContent = data.title;
        }
      });
    }
  }
}

async function lookup() {
  const wid = extractId(document.getElementById("workshop-id").value);
  if (!wid) return;
  document.getElementById("lookup-result").innerHTML = '<span class="loading">Looking up...</span>';
  const data = await api("GET", "/api/lookup/" + wid);
  document.getElementById("lookup-result").innerHTML = data.title
    ? '<span style="color:#4caf50">Found: ' + data.title + "</span>" : '<span style="color:#888">Title not found</span>';
}

async function addMod() {
  const wid = extractId(document.getElementById("workshop-id").value);
  const mid = document.getElementById("mod-id").value.trim();
  if (!wid) return;
  const st = document.getElementById("add-status");
  try {
    await api("POST", "/api/mods", { workshop_id: wid, mod_id: mid });
    st.className = "status ok"; st.textContent = "Mod added!";
    document.getElementById("workshop-id").value = "";
    document.getElementById("mod-id").value = "";
    document.getElementById("lookup-result").innerHTML = "";
    loadMods();
  } catch (e) {
    st.className = "status err"; st.textContent = "Error: " + e.message;
  }
  setTimeout(() => { st.className = "status"; }, 3000);
}

async function removeMod(idx) {
  if (!confirm("Remove this mod?")) return;
  await api("DELETE", "/api/mods/" + idx);
  loadMods();
}

loadMods();
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass

    def check_auth(self):
        auth = self.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            decoded = base64.b64decode(auth[6:]).decode("utf-8", errors="replace")
            if ":" in decoded and decoded.split(":", 1)[1] == PASSWORD:
                return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="PZ Mod Manager"')
        self.send_header("Content-Length", "0")
        self.end_headers()
        return False

    def send_json(self, data, code=200):
        body = json.dumps(data).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self):
        body = HTML.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.check_auth():
            return
        if self.path == "/api/mods":
            self.send_json(read_mods())
        elif self.path.startswith("/api/lookup/"):
            wid = self.path.split("/")[-1]
            title = fetch_workshop_title(wid)
            self.send_json({"workshop_id": wid, "title": title})
        else:
            self.send_html()

    def do_POST(self):
        if not self.check_auth():
            return
        if self.path == "/api/mods":
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(length))
            wid = re.search(r"id=(\d+)", data.get("workshop_id", ""))
            workshop_id = wid.group(1) if wid else data.get("workshop_id", "").strip()
            mod_id = data.get("mod_id", "").strip()
            if not workshop_id:
                self.send_json({"error": "workshop_id required"}, 400)
                return
            mods = read_mods()
            if any(m["workshop_id"] == workshop_id for m in mods):
                self.send_json({"error": "mod already added"}, 409)
                return
            mods.append({"workshop_id": workshop_id, "mod_id": mod_id})
            write_mods(mods)
            self.send_json({"ok": True})
        else:
            self.send_json({"error": "not found"}, 404)

    def do_DELETE(self):
        if not self.check_auth():
            return
        if self.path.startswith("/api/mods/"):
            try:
                idx = int(self.path.split("/")[-1])
                mods = read_mods()
                if 0 <= idx < len(mods):
                    mods.pop(idx)
                    write_mods(mods)
                    self.send_json({"ok": True})
                else:
                    self.send_json({"error": "index out of range"}, 404)
            except ValueError:
                self.send_json({"error": "invalid index"}, 400)
        else:
            self.send_json({"error": "not found"}, 404)


if __name__ == "__main__":
    print(f"mod-manager: listening on port {PORT}")
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
