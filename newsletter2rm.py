"""Send new posts from a Substack RSS feed to a reMarkable as device-sized PDFs.

Flow: RSS -> clean HTML (grayscale, inlined images) -> Chromium PDF -> rmapi put.
"""

import argparse
import base64
import email.utils
import html
import io
import json
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path

import requests
from bs4 import BeautifulSoup
from PIL import Image, ImageOps
from playwright.sync_api import sync_playwright

FEED_URL = os.environ.get("FEED_URL", "https://newsletter.eng-leadership.com/feed")
STATE_URI = os.environ.get("STATE_URI", "state.json")  # local path or gs://bucket/key
RM_FOLDER = os.environ.get("RM_FOLDER", "/Newsletters")
BACKFILL = int(os.environ.get("BACKFILL", "3"))  # posts sent on the very first run

# reMarkable 2: 1404x1872 px at 226 dpi.
PAGE_W_MM, PAGE_H_MM = 157.8, 210.4
MARGIN_MM = 9
MAX_IMG_PX = round((PAGE_W_MM - 2 * MARGIN_MM) / 25.4 * 226)

HERE = Path(__file__).parent
CONTENT_NS = "{http://purl.org/rss/1.0/modules/content/}encoded"
UA = "Mozilla/5.0 (X11; Linux x86_64) newsletter2rm"

# Substack UI chrome that means nothing on paper.
DROP_SELECTORS = [
    "script", "style", "iframe", "button", "svg", "source",
    ".image-link-expand", ".button-wrapper", ".subscription-widget-wrap",
    ".subscription-widget", ".share-dialog", ".post-ufi", ".captioned-button-wrap",
]

log = logging.getLogger("newsletter2rm")


# --- state -------------------------------------------------------------------

def load_state():
    if STATE_URI.startswith("gs://"):
        blob = _gcs_blob()
        return json.loads(blob.download_as_text()) if blob.exists() else None
    p = Path(STATE_URI)
    return json.loads(p.read_text()) if p.exists() else None


def save_state(state):
    data = json.dumps(state, indent=1)
    if STATE_URI.startswith("gs://"):
        _gcs_blob().upload_from_string(data, content_type="application/json")
    else:
        Path(STATE_URI).write_text(data)


def _gcs_blob():
    from google.cloud import storage

    bucket, _, key = STATE_URI[5:].partition("/")
    return storage.Client().bucket(bucket).blob(key or "state.json")


# --- feed --------------------------------------------------------------------

def fetch_feed():
    r = requests.get(FEED_URL, headers={"User-Agent": UA}, timeout=30)
    r.raise_for_status()
    channel = ET.fromstring(r.content).find("channel")
    posts = []
    for item in channel.findall("item"):
        posts.append({
            "id": item.findtext("guid") or item.findtext("link"),
            "title": html.unescape(item.findtext("title", "")).strip(),
            # Substack double-encodes entities in <description>.
            "subtitle": html.unescape(item.findtext("description", "")).strip(),
            "link": item.findtext("link"),
            "author": item.findtext("{http://purl.org/dc/elements/1.1/}creator", ""),
            "date": email.utils.parsedate_to_datetime(item.findtext("pubDate")),
            "html": item.findtext(CONTENT_NS, ""),
        })
    posts.sort(key=lambda p: p["date"])
    return posts, channel.findtext("title", "")


# --- html cleanup --------------------------------------------------------------

def image_data_uri(url):
    r = requests.get(url, headers={"User-Agent": UA}, timeout=30)
    r.raise_for_status()
    img = Image.open(io.BytesIO(r.content))
    img.seek(0)  # first frame of animated gifs
    lossless = img.format in ("PNG", "GIF", "WEBP") and img.info.get("lossless", img.format != "WEBP")
    has_alpha = img.mode in ("RGBA", "LA", "P")
    if has_alpha:
        img = img.convert("RGBA")
        bg = Image.new("RGBA", img.size, "white")
        img = Image.alpha_composite(bg, img)
    img = ImageOps.grayscale(img)
    if img.width > MAX_IMG_PX:
        img = img.resize((MAX_IMG_PX, round(img.height * MAX_IMG_PX / img.width)), Image.LANCZOS)
    buf = io.BytesIO()
    # PNG keeps diagrams/screenshots crisp; JPEG keeps photos small.
    if has_alpha or lossless:
        img.save(buf, "PNG", optimize=True)
        mime = "image/png"
    else:
        img.save(buf, "JPEG", quality=88, optimize=True)
        mime = "image/jpeg"
    return f"data:{mime};base64,{base64.b64encode(buf.getvalue()).decode()}"


def original_image_url(img):
    """Prefer the full-size original over Substack's resized/webp variants."""
    try:
        src = json.loads(img.get("data-attrs", "{}")).get("src")
        if src:
            return src
    except ValueError:
        pass
    return img.get("src")


def clean_html(raw):
    soup = BeautifulSoup(raw, "html.parser")
    for sel in DROP_SELECTORS:
        for el in soup.select(sel):
            el.decompose()

    # The trailing "Read more" link on paywalled posts.
    for a in soup.find_all("a"):
        if a.get_text(strip=True).lower() == "read more":
            (a.find_parent("p") or a).decompose()

    for img in soup.find_all("img"):
        url = original_image_url(img)
        # Unwrap the <a><div><picture> nesting around each image.
        wrapper = img.find_parent("a", class_="image-link")
        if wrapper:
            wrapper.replace_with(img)
        for attr in list(img.attrs):
            if attr not in ("alt",):
                del img[attr]
        try:
            img["src"] = image_data_uri(url)
        except Exception as e:
            log.warning("image %s failed: %s", url, e)
            img.decompose()

    for pic in soup.find_all("picture"):
        pic.unwrap()
    for div in soup.select("div.image2-inset"):
        div.unwrap()
    return str(soup)


def build_document(post, publication):
    style = (HERE / "style.css").read_text()
    style = style.replace("PAGE_SIZE", f"{PAGE_W_MM}mm {PAGE_H_MM}mm").replace("PAGE_MARGIN", f"{MARGIN_MM}mm")
    e = html.escape
    subtitle = f'<p class="subtitle">{e(post["subtitle"])}</p>' if post["subtitle"] else ""
    paywalled = '<p class="paywall">Free preview. Continue reading at ' \
                f'{e(post["link"])}</p>' if re.search(r">\s*Read more\s*<", post["html"]) else ""
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{e(post["title"])}</title><style>{style}</style></head>
<body>
<header>
  <p class="kicker">{e(publication)}</p>
  <h1>{e(post["title"])}</h1>
  {subtitle}
  <p class="byline">{e(post["author"])} · {post["date"]:%-d %B %Y}</p>
</header>
<article>{clean_html(post["html"])}</article>
{paywalled}
</body></html>"""


# --- output ------------------------------------------------------------------

def render_pdf(browser, document, out_path):
    page = browser.new_page()
    page.set_content(document, wait_until="load")
    page.pdf(path=str(out_path), prefer_css_page_size=True, print_background=True)
    page.close()


def file_name(post):
    title = re.sub(r'[\\/:*?"<>|]+', "", post["title"])
    title = "".join(c for c in title if unicodedata.category(c) != "So").strip()  # emoji
    return f"{post['date']:%Y-%m-%d} {title}"[:120]


def rmapi(*args, check=True):
    log.info("rmapi %s", " ".join(args))
    return subprocess.run(["rmapi", *args], check=check, capture_output=True, text=True)


def upload(pdf_path):
    rmapi("put", str(pdf_path), RM_FOLDER)


# --- main --------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="render PDFs into --out, don't upload or save state")
    ap.add_argument("--out", default=None, help="directory to keep rendered PDFs")
    ap.add_argument("--limit", type=int, default=None, help="dry-run: number of latest posts to render")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    posts, publication = fetch_feed()
    state = None if args.dry_run else load_state()

    if args.dry_run:
        todo = posts[-(args.limit or BACKFILL):]
    elif state is None:
        log.info("first run: sending the latest %d posts, marking the rest as seen", BACKFILL)
        todo = posts[-BACKFILL:] if BACKFILL else []
        state = {"sent": [p["id"] for p in posts if p not in todo]}
    else:
        todo = [p for p in posts if p["id"] not in state["sent"]]

    if not todo:
        log.info("nothing new")
        return

    out_dir = Path(args.out or tempfile.mkdtemp())
    out_dir.mkdir(parents=True, exist_ok=True)
    if not args.dry_run:
        rmapi("mkdir", RM_FOLDER, check=False)  # fails harmlessly if it exists

    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        for post in todo:
            pdf = out_dir / f"{file_name(post)}.pdf"
            log.info("rendering %s", pdf.name)
            render_pdf(browser, build_document(post, publication), pdf)
            if args.dry_run:
                continue
            upload(pdf)
            state["sent"].append(post["id"])
            save_state(state)  # after each upload, so a crash never re-sends
        browser.close()

    if not args.out:
        shutil.rmtree(out_dir, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as e:
        log.error("rmapi failed (exit %s): %s %s", e.returncode, e.stdout, e.stderr)
        sys.exit(1)
