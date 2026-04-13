"""User service — BAD: no global exception handler."""
from fastapi import FastAPI

app = FastAPI()


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.post("/api/v1/users")
async def create_user(payload: dict):
    result = process(payload)
    return {"data": result}


@app.delete("/api/v1/users/{user_id}")
async def delete_user(user_id: str):
    remove_user(user_id)
    return {"deleted": True}
