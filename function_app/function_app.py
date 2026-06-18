import json
import logging
import os
import socket
import ssl
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

import azure.functions as func
from azure.cosmos import CosmosClient, PartitionKey
from azure.identity import DefaultAzureCredential

app = func.FunctionApp()

COSMOS_ENDPOINT = os.environ["COSMOS_ENDPOINT"]
COSMOS_DATABASE = os.environ["COSMOS_DATABASE"]
COSMOS_CONTAINER = os.environ["COSMOS_CONTAINER"]
CHECK_URL = os.environ["CHECK_URL"]
CONTENT_CHECK = os.environ.get("CONTENT_CHECK", "")
SSL_WARN_DAYS = int(os.environ.get("SSL_WARN_DAYS", "30"))
SSL_ALERT_DAYS = int(os.environ.get("SSL_ALERT_DAYS", "7"))

MAX_RETRIES = 1

# Cosmos data-plane access via the function's managed identity (no keys).
_credential = DefaultAzureCredential()
_cosmos = CosmosClient(COSMOS_ENDPOINT, credential=_credential)
_container = _cosmos.get_database_client(COSMOS_DATABASE).get_container_client(COSMOS_CONTAINER)


def _http_check(url):
    """Returns (status_code, latency_ms, is_healthy, content_ok, error_message)."""
    start = time.monotonic()
    try:
        req = urllib.request.Request(url, method="GET")
        req.add_header("User-Agent", "UptimeMonitor/1.0")
        with urllib.request.urlopen(req, timeout=10) as response:  # noqa: S310 (https only)
            status_code = response.getcode()
            body = response.read(8192).decode("utf-8", errors="ignore")
            latency_ms = round((time.monotonic() - start) * 1000)
            status_ok = 200 <= status_code < 400
            content_ok = (CONTENT_CHECK.lower() in body.lower()) if CONTENT_CHECK else True
            return status_code, latency_ms, status_ok and content_ok, content_ok, None
    except urllib.error.HTTPError as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        return e.code, latency_ms, False, False, str(e.reason)
    except urllib.error.URLError as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        return None, latency_ms, False, False, str(e.reason)
    except Exception as e:
        latency_ms = round((time.monotonic() - start) * 1000)
        return None, latency_ms, False, False, str(e)


def _ssl_days_remaining(hostname):
    """Returns days until the SSL cert expires, or None on error."""
    try:
        ctx = ssl.create_default_context()
        with ctx.wrap_socket(
            socket.create_connection((hostname, 443), timeout=10),
            server_hostname=hostname,
        ) as sock:
            cert = sock.getpeercert()
            expiry = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
            return (expiry - datetime.now(timezone.utc)).days
    except Exception:
        return None


@app.timer_trigger(schedule="0 */5 * * * *", arg_name="timer", run_on_startup=False)
def uptime_check(timer: func.TimerRequest) -> None:
    now = datetime.now(timezone.utc)
    timestamp = now.isoformat()
    check_id = CHECK_URL.replace("https://", "").replace("http://", "").rstrip("/")

    # HTTP check with one retry on failure to suppress transient flaps.
    status_code, latency_ms, is_healthy, content_ok, error_message = _http_check(CHECK_URL)
    if not is_healthy:
        time.sleep(5)
        status_code, latency_ms, is_healthy, content_ok, error_message = _http_check(CHECK_URL)

    hostname = check_id.split("/")[0]
    ssl_days = _ssl_days_remaining(hostname) if CHECK_URL.startswith("https://") else None

    item = {
        "id": str(uuid.uuid4()),
        "check_id": check_id,
        "timestamp": timestamp,
        "status_code": status_code if status_code else 0,
        "latency_ms": latency_ms,
        "is_healthy": is_healthy,
        "content_ok": content_ok,
        "ssl_days_remaining": ssl_days,
    }
    if error_message:
        item["error"] = error_message

    _container.upsert_item(item)

    # Structured log -> Application Insights customDimensions. KQL scheduled-query
    # alerts (site-down, high-latency) run over these records; this is the Azure
    # analog to emitting custom CloudWatch metrics and alarming on them.
    logging.info(
        "uptime_result %s",
        json.dumps({
            "check_id": check_id,
            "is_healthy": 1 if is_healthy else 0,
            "latency_ms": latency_ms,
            "status_code": item["status_code"],
            "ssl_days_remaining": ssl_days if ssl_days is not None else -1,
            "content_ok": content_ok,
            "error": error_message or "",
        }),
    )
