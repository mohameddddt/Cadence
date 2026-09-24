FROM python:3.12-slim

# ffmpeg: audio extraction, conversion, thumbnails.  chromaprint: fpcalc for /fingerprint.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg libchromaprint-tools ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV MP_WORKDIR=/data
VOLUME /data
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8000/health')"

# One worker on purpose: job state lives in memory.
CMD ["uvicorn", "app.main:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000"]
