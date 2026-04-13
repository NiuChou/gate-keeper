"""Rate limiter that does not set retry header on 429."""
from fastapi import Request
from starlette.responses import JSONResponse
from starlette.status import HTTP_429_TOO_MANY_REQUESTS


class SimpleRateLimiter:
    async def check(self, request: Request):
        if self.over_limit(request):
            return JSONResponse(
                status_code=HTTP_429_TOO_MANY_REQUESTS,
                content={"detail": "Rate limit reached"},
            )
        return None
