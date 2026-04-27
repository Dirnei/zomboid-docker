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
        desc_m = re.search(r'<div class="workshopItemDescription"[^>]*>(.*?)</div>', html, re.DOTALL)
        description = None
        if desc_m:
            desc = desc_m.group(1).strip()
            desc = re.sub(r'<br\s*/?>', '\n', desc)
            desc = re.sub(r'<[^>]+>', '', desc)
            desc = re.sub(r'\n{3,}', '\n\n', desc).strip()
            if len(desc) > 1000:
                desc = desc[:1000] + "..."
            description = desc
        return {
            "title": title_m.group(1).strip() if title_m else None,
            "image": img_m.group(1).strip() if img_m else None,
            "description": description,
        }
    except Exception:
        return {"title": None, "image": None}
