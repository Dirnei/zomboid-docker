import time
import hashlib
from config import BOARD_STALE_DAYS


def create_post(state, session, post_type, text, location=""):
    post_id = hashlib.sha256(f"{session['username']}{time.time()}".encode()).hexdigest()[:8]
    post = {
        "id": post_id,
        "type": post_type,
        "text": text,
        "location": location,
        "author": session["username"],
        "created_at": time.strftime("%Y-%m-%d %H:%M"),
    }
    state.setdefault("posts", []).append(post)
    return post


def list_posts(state):
    posts = state.get("posts", [])
    now = time.time()
    result = []
    for p in posts:
        post = dict(p)
        try:
            from datetime import datetime
            created = datetime.strptime(p["created_at"], "%Y-%m-%d %H:%M")
            age_days = (now - created.timestamp()) / 86400
            post["stale"] = age_days >= BOARD_STALE_DAYS
        except Exception:
            post["stale"] = False
        result.append(post)
    fresh = [p for p in result if not p["stale"]]
    stale = [p for p in result if p["stale"]]
    fresh.sort(key=lambda p: p["created_at"], reverse=True)
    stale.sort(key=lambda p: p["created_at"], reverse=True)
    return fresh + stale


def delete_post(state, post_id, session):
    posts = state.get("posts", [])
    for i, p in enumerate(posts):
        if p["id"] == post_id:
            if p["author"] == session["username"] or session["role"] == "admin":
                return posts.pop(i)
            return None
    return None
