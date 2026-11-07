"""Replacement for plane_mcp/auth/plane_header_auth_provider.py in plane-mcp-server v0.3.0 (PET-882).

Upstream validates the API key with GET /api/v1/users/me/ on every HTTP request, so one tool call
spends 3-4 of Plane's 120-per-minute budget on validation alone, and it turns a 429 from that
call into a 401 that makes the client discard its authorization. This version:

* caches a successful validation per key (hash only, never the key) for PLANE_KEY_CACHE_TTL
  seconds (default 300);
* collapses concurrent validations of one key into one call;
* reads X-Ratelimit-Remaining / X-Ratelimit-Reset from Plane and stops validating while the
  budget is under PLANE_KEY_RATE_FLOOR (default 10) or after a 429, trusting a key that
  validated before for PLANE_KEY_STALE_GRACE seconds (default 3600);
* returns None (a 401) only when Plane answers 401 or 403, never for a 429, a 5xx or a timeout
  on a key that validated before.

Dockerfile in this directory copies this file over the upstream module. Keep the class and
method names equal to upstream: plane_mcp imports PlaneHeaderAuthProvider.
"""

import asyncio
import hashlib
import os
import time

import httpx
from fastmcp.server.auth import TokenVerifier
from fastmcp.server.auth.auth import AccessToken
from fastmcp.utilities.logging import get_logger

logger = get_logger(__name__)

DEFAULT_PLANE_BASE_URL = "https://api.plane.so"


def _int_env(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, default))
    except ValueError:
        return default


class PlaneHeaderAuthProvider(TokenVerifier):
    def __init__(self, required_scopes: list[str] | None = None, timeout_seconds: int = 10):
        super().__init__(required_scopes=required_scopes)
        self.timeout_seconds = timeout_seconds
        self.cache_ttl = _int_env("PLANE_KEY_CACHE_TTL", 300)
        self.stale_grace = _int_env("PLANE_KEY_STALE_GRACE", 3600)
        self.rate_floor = _int_env("PLANE_KEY_RATE_FLOOR", 10)
        self._last_ok: dict[str, float] = {}  # key hash -> time.time() of last validation
        self._locks: dict[str, asyncio.Lock] = {}
        self._paused_until = 0.0  # time.time() before which Plane gets no validation call

    @staticmethod
    def _digest(token: str) -> str:
        return hashlib.sha256(token.encode()).hexdigest()

    def _known_good(self, digest: str, within: int) -> bool:
        ok = self._last_ok.get(digest)
        return ok is not None and time.time() - ok < within

    def _note_budget(self, response: httpx.Response) -> None:
        """Pause validation when Plane reports an exhausted or nearly exhausted budget."""
        try:
            remaining = int(response.headers.get("x-ratelimit-remaining", ""))
            reset = float(response.headers.get("x-ratelimit-reset", ""))
        except ValueError:
            return
        if response.status_code == 429 or remaining < self.rate_floor:
            self._paused_until = max(self._paused_until, reset)
            logger.warning("Plane API budget low (remaining=%s); pausing key validation until %s", remaining, reset)

    async def _validate_api_key(self, token: str) -> bool | None:
        """Return True (valid), False (Plane rejected the key) or None (could not tell)."""
        base_url = (os.getenv("PLANE_INTERNAL_BASE_URL") or os.getenv("PLANE_BASE_URL", DEFAULT_PLANE_BASE_URL)).rstrip(
            "/"
        )
        user_url = f"{base_url}/api/v1/users/me/"
        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                response = await client.get(
                    user_url,
                    headers={"x-api-key": token, "Content-Type": "application/json"},
                )
        except httpx.RequestError as e:
            logger.warning("API key validation request failed: %s", e)
            return None
        self._note_budget(response)
        if response.status_code == 200:
            return True
        logger.warning("API key validation failed: %s", response.status_code)
        if response.status_code in (401, 403):
            return False
        return None  # 429, 5xx and anything else say nothing about the key

    async def _is_valid(self, token: str) -> bool:
        digest = self._digest(token)
        if self._known_good(digest, self.cache_ttl):
            return True
        lock = self._locks.setdefault(digest, asyncio.Lock())
        async with lock:
            if self._known_good(digest, self.cache_ttl):  # another request validated it
                return True
            if time.time() < self._paused_until and self._known_good(digest, self.stale_grace):
                return True
            result = await self._validate_api_key(token)
            if result is None and not self._known_good(digest, self.stale_grace):
                # A key never seen valid, and Plane is limiting us: wait out a short window once.
                wait = min(max(self._paused_until - time.time(), 1.0), 5.0)
                await asyncio.sleep(wait)
                result = await self._validate_api_key(token)
            if result is True:
                self._last_ok[digest] = time.time()
                return True
            if result is False:
                self._last_ok.pop(digest, None)
                return False
            if self._known_good(digest, self.stale_grace):
                logger.warning("Plane could not validate the key; trusting an earlier validation")
                return True
            return False

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            from fastmcp.server.dependencies import get_http_headers

            headers = get_http_headers()

            if token:
                workspace_slug = headers.get("x-workspace-slug")
                if not workspace_slug:
                    logger.warning("x-api-key header found but x-workspace-slug is missing")
                    return None

                if not await self._is_valid(token):
                    logger.warning("API key validation against Plane API failed")
                    return None

                expires_at = int(time.time() + 3600)
                return AccessToken(
                    token=token,
                    client_id="api_key_header_user",
                    scopes=["read", "write"],
                    expires_at=expires_at,
                    claims={
                        "auth_method": "api_key_header",
                        "workspace_slug": workspace_slug,
                    },
                )
        except RuntimeError:
            # No active HTTP request available (e.g., stdio transport)
            logger.debug("No active HTTP request available for header check")
