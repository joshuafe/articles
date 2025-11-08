from __future__ import annotations

import datetime as dt
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from .storage import Reminder, ReminderStore

app = FastAPI(title="Reminder Board Service")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"]
)

STORE = ReminderStore(Path(__file__).resolve().parent / "data" / "reminders.json")


class ReminderCreate(BaseModel):
    text: str = Field(..., min_length=1, max_length=280)
    created_at: dt.datetime = Field(default_factory=lambda: dt.datetime.now(dt.timezone.utc))

    def to_model(self) -> Reminder:
        return Reminder(text=self.text.strip(), created_at=self.created_at.astimezone(dt.timezone.utc).isoformat())


class ReminderResponse(BaseModel):
    text: str
    created_at: dt.datetime

    @classmethod
    def from_model(cls, reminder: Reminder) -> "ReminderResponse":
        created = reminder.created_at.replace("Z", "+00:00")
        return cls(text=reminder.text, created_at=dt.datetime.fromisoformat(created))


def verify_api_key(x_api_key: Annotated[str | None, Header()] = None) -> None:
    expected = (Path(__file__).resolve().parent / "API_KEY.txt")
    if expected.exists():
        token = expected.read_text(encoding="utf-8").strip()
        if token and token != (x_api_key or ""):
            raise HTTPException(status_code=401, detail="Invalid API key")


@app.get("/reminders", response_model=list[ReminderResponse])
def list_reminders() -> list[ReminderResponse]:
    reminders = STORE.list()
    return [ReminderResponse.from_model(item) for item in reminders]


@app.post("/reminders", status_code=201)
def create_reminder(payload: ReminderCreate, _: Annotated[None, Depends(verify_api_key)]) -> Response:
    reminder = payload.to_model()
    STORE.add(reminder)
    return Response(status_code=201)


@app.get("/", response_class=HTMLResponse)
def render_board() -> str:
    html_path = Path(__file__).resolve().parent / "static" / "index.html"
    return html_path.read_text(encoding="utf-8")
