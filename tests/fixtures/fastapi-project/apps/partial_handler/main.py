"""Partial handler — BAD: only HTTPException handler, no generic Exception handler.
This is the exact pattern that caused the 500 error in the Notion session:
generic exceptions fall through as opaque 500 responses.
"""
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

app = FastAPI()


async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


app.add_exception_handler(HTTPException, http_exception_handler)


@app.post("/api/v1/sessions")
async def create_session(payload: dict):
    result = process(payload)
    return {"data": result}
