"""Local observation opt-in, independent of the unmerged account/auth branch.

This is a local demo boundary, not user authentication or session ownership.
Do not enable it on a publicly accessible backend.
"""
import ipaddress
import os

from fastapi import HTTPException, Request


def local_observations_allowed(request: Request) -> bool:
    if os.getenv("BEACON_OBSERVATIONS_LOCAL", "") != "1":
        return False
    try:
        return bool(request.client and ipaddress.ip_address(request.client.host).is_loopback)
    except ValueError:
        return False


def require_local_observations(request: Request) -> None:
    if os.getenv("BEACON_OBSERVATIONS_LOCAL", "") != "1":
        raise HTTPException(404, "Local BLE observations are disabled")
    if not local_observations_allowed(request):
        raise HTTPException(403, "Local BLE observations require a loopback connection")
