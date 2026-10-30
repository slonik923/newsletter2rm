# newsletter2rm

Sends new posts from a Substack newsletter (default: newsletter.eng-leadership.com) to a
reMarkable 2 as PDFs sized exactly to the screen (157.8 × 210.4 mm), with grayscale images
and e-ink friendly typography. Uses only the public RSS feed, so there's no login to break.

Flow: RSS → clean HTML (images downloaded at full size, grayscale, inlined) → headless
Chromium PDF → `rmapi put /Newsletters`.

## Local

```sh
docker build -t newsletter2rm .

# Render the latest 5 posts into ./out without uploading
docker run --rm -u $(id -u):$(id -g) -e HOME=/tmp -v $PWD/out:/out newsletter2rm --dry-run --limit 5 --out /out
```

### Pair with reMarkable cloud (once)

Get a one-time code at https://my.remarkable.com/device/browser/connect, then:

```sh
touch rmapi.conf
echo CODE | docker run --rm -i -v $PWD/rmapi.conf:/tmp/rmapi.conf newsletter2rm rmapi ls
```

`rmapi.conf` now holds a device token, valid until you remove the device in your reMarkable
account. It is git-ignored.

### Real run locally

```sh
docker run --rm -v $PWD/rmapi.conf:/tmp/rmapi.conf -v $PWD:/state -e STATE_URI=/state/state.json newsletter2rm
```

The first run (no state file) sends the latest `BACKFILL` (default 3) posts and marks the
rest as seen. Later runs send only new posts.

## Deploy to GCP

```sh
PROJECT=my-project ./deploy.sh
```

Creates a Cloud Run Job, a Cloud Scheduler trigger (every 3 h), a GCS bucket for state and a
Secret Manager secret with `rmapi.conf`. It all fits in the free tier.

## Settings (env vars)

| var | default |
| --- | --- |
| `FEED_URL` | `https://newsletter.eng-leadership.com/feed` |
| `RM_FOLDER` | `/Newsletters` |
| `BACKFILL` | `3` |
| `STATE_URI` | `state.json` (local path or `gs://bucket/key`) |

Look tweaks: `style.css`. Page size and margins: constants at the top of `newsletter2rm.py`.
