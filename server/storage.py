from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from threading import Lock
from typing import List


@dataclass
class Reminder:
    text: str
    created_at: str


class ReminderStore:
    def __init__(self, path: Path, max_items: int = 32) -> None:
        self._path = path
        self._max_items = max_items
        self._lock = Lock()
        self._path.parent.mkdir(parents=True, exist_ok=True)
        if not self._path.exists():
            self._path.write_text("[]", encoding="utf-8")

    def add(self, reminder: Reminder) -> None:
        with self._lock:
            reminders = self._load_all()
            reminders.append(reminder)
            reminders = reminders[-self._max_items :]
            data = [asdict(item) for item in reminders]
            self._path.write_text(json.dumps(data, indent=2), encoding="utf-8")

    def list(self) -> List[Reminder]:
        with self._lock:
            return self._load_all()

    def _load_all(self) -> List[Reminder]:
        if not self._path.exists():
            return []
        raw = json.loads(self._path.read_text(encoding="utf-8"))
        reminders: List[Reminder] = [Reminder(**item) for item in raw]
        return reminders
