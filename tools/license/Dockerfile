FROM docker.1ms.run/library/python:3.12-slim

WORKDIR /app

RUN pip install --no-cache-dir flask==3.1.1

COPY ed25519.py license_server.py ./

ENV LICENSE_DATA_DIR=/data \
    PYTHONUNBUFFERED=1

EXPOSE 8789

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8789/healthz', timeout=3)"

CMD ["python", "license_server.py"]
