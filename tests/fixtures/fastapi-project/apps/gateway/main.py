"""Gateway service — GOOD: has both Exception and HTTPException handlers."""
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

app = FastAPI()


async def global_exception_handler(request: Request, exc: Exception):
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})


async def http_exception_handler(request: Request, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


app.add_exception_handler(Exception, global_exception_handler)
app.add_exception_handler(HTTPException, http_exception_handler)


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.post("/api/v1/data")
async def create_data(payload: dict):
    try:
        result = process(payload)
        return {"data": result}
    except ValueError as e:
        return JSONResponse(status_code=400, content={"detail": str(e)})
