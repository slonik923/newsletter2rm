# newsletter2rm

Sends new posts from a Substack newsletter to a reMarkable 2 as PDFs sized exactly to the
screen (157.8 × 210.4 mm), with grayscale images and e-ink friendly typography. Uses only
the public RSS feed, so there's no login to break. Point `FEED_URL` at any Substack (or any
RSS feed with full `content:encoded` HTML). Paywalled posts get the free preview plus a link.

Not affiliated with reMarkable or Substack. Uploads use [rmapi](https://github.com/ddvk/rmapi).

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
mkdir -p rmapi
echo CODE | docker run --rm -i -v $PWD/rmapi:/rmapi -e RMAPI_CONFIG=/rmapi/rmapi.conf newsletter2rm rmapi ls
```

`rmapi/rmapi.conf` now holds a device token, valid until you remove the device in your reMarkable
account. It is git-ignored. (Mount the directory, not the file: rmapi replaces the file on save.)

### Real run locally

```sh
docker run --rm -v $PWD/rmapi:/rmapi -e RMAPI_CONFIG=/rmapi/rmapi.conf -v $PWD:/state -e STATE_URI=/state/state.json newsletter2rm
```

The first run (no state file) sends the latest `BACKFILL` (default 3) posts and marks the
rest as seen. Later runs send only new posts.

## Deploy to GCP

```sh
PROJECT=my-project ./deploy.sh
```

Builds the image locally (Docker), pushes it to Artifact Registry and creates a Cloud Run Job,
a Cloud Scheduler trigger (every 3 h), a GCS bucket for state and a Secret Manager secret with
`rmapi/rmapi.conf`. It all fits in the free tier.

### Continuous deploy from GitHub

```sh
PROJECT=my-project REPO=owner/newsletter2rm ./setup-github-deploy.sh
```

Sets up Workload Identity Federation so `.github/workflows/deploy.yml` can authenticate without
a stored key, and a `github-deployer` service account that can only push images and update the
job. Put the printed values into the workflow's `env`. After that, every push to `master`
builds the image on GitHub and points the job at it. `deploy.sh` is only needed again to change
the schedule, secret or other infrastructure.

### Failure alert

```sh
PROJECT=my-project ALERT_EMAIL=me@example.com ./setup-alert.sh
```

Emails you when a job execution fails, for example when the rmapi token is revoked or the
feed is unreachable. Test it with a one-off failing run (the job's own config is untouched):
`gcloud run jobs execute newsletter2rm --region europe-west3 --update-env-vars FEED_URL=https://example.com/nope`

## Settings (env vars)

| var | default |
| --- | --- |
| `FEED_URL` | `https://newsletter.eng-leadership.com/feed` |
| `RM_FOLDER` | `/Newsletters` |
| `BACKFILL` | `3` |
| `STATE_URI` | `state.json` (local path or `gs://bucket/key`) |

Look tweaks: `style.css`. Page size and margins: constants at the top of `newsletter2rm.py`.
