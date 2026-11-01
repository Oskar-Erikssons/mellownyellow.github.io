"""Consent gate: the tools only send data off your computer when you say so.

A URL counts as local when it points at this computer or your home network
(localhost, 127.x, ::1, 10.x, 172.16-31.x, 192.168.x or a .local name).
Anything else needs --allow-remote on the command line.
"""

from __future__ import annotations

import ipaddress
from urllib.parse import urlparse


def is_local(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    if host in ("localhost", "") or host.endswith(".local") or host.endswith(".localhost"):
        return host != ""
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private or ip.is_link_local


def require_consent(url: str, allowed: bool, what: str) -> None:
    """Stops the program unless the URL is local or the user passed --allow-remote."""
    if not is_local(url) and not allowed:
        raise SystemExit(
            f"Stopped: {what} would be sent to {urlparse(url).hostname}, outside your computer and home network.\n"
            f"Add --allow-remote if you agree to that.")
