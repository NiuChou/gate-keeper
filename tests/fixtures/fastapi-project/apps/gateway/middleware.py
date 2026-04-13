"""Rate limiting middleware with proper 429 handling."""
from fastapi import Request
from starlette.responses import JSONResponse
from starlette.status import HTTP_429_TOO_MANY_REQUESTS


class RateLimitMiddleware:
    async def dispatch(self, request: Request, call_next):
        if self.is_rate_limited(request):
            return JSONResponse(
                status_code=HTTP_429_TOO_MANY_REQUESTS,
                content={"detail": "Too many requests"},
                headers={"Retry-After": str(self.retry_after_seconds)},
            )
        return await call_next(request)
