import re
import urllib.request


def fetch_workshop_info(workshop_id):
    try:
        url = f"https://steamcommunity.com/sharedfiles/filedetails/?id={workshop_id}"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            html = resp.read().decode("utf-8", errors="replace")
        title_m = re.search(r'<div class="workshopItemTitle">([^<]+)</div>', html)
        img_m = re.search(r'<img[^>]+id="previewImageMain"[^>]+src="([^"]+)"', html)
        if not img_m:
            img_m = re.search(r'<img[^>]+class="workshopItemPreviewImageMain"[^>]+src="([^"]+)"', html)
        return {
            "title": title_m.group(1).strip() if title_m else None,
            "image": img_m.group(1).strip() if img_m else None,
        }
    except Exception:
        return {"title": None, "image": None}
