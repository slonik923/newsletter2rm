FROM python:3.12-slim-bookworm

ARG RMAPI_VERSION=v0.0.35

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl ca-certificates fonts-noto-core \
 && curl -fsSL "https://github.com/ddvk/rmapi/releases/download/${RMAPI_VERSION}/rmapi-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin rmapi \
 && rm -rf /var/lib/apt/lists/*

ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && playwright install --with-deps chromium \
 && rm -rf /var/lib/apt/lists/*

COPY newsletter2rm.py style.css entrypoint.sh ./

# rmapi rewrites its config when it refreshes tokens, so it needs a writable copy.
ENV RMAPI_CONFIG=/tmp/rmapi.conf
ENTRYPOINT ["/app/entrypoint.sh"]
