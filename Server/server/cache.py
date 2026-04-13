import time
from collections import OrderedDict
from typing import Any, Optional, Tuple


class TTLCache:
    def __init__(self, max_items: int = 128, ttl_seconds: int = 300):
        self.max_items = max_items
        self.ttl_seconds = ttl_seconds
        self._data: OrderedDict[str, Tuple[float, Any]] = OrderedDict()

    def get(self, key: str) -> Optional[Any]:
        if key not in self._data:
            return None
        ts, val = self._data[key]
        if (time.monotonic() - ts) > self.ttl_seconds:
            del self._data[key]
            return None
        self._data.move_to_end(key)
        return val

    def set(self, key: str, val: Any) -> None:
        self._data[key] = (time.monotonic(), val)
        self._data.move_to_end(key)
        while len(self._data) > self.max_items:
            self._data.popitem(last=False)
