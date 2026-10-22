"""Minimal reader for WoW SavedVariables files (Lua table literals).

Handles the subset WoW writes: strings, numbers, booleans, nil, nested tables,
["key"] = value / [1] = value / bare values, and "-- [n]" comments.
"""

from __future__ import annotations

import re

_NUMBER = re.compile(rb"-?(?:0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)")
_NAME = re.compile(rb"[A-Za-z_][A-Za-z0-9_]*")
_ESCAPES = {ord("n"): b"\n", ord("t"): b"\t", ord("r"): b"\r", ord("a"): b"\a",
            ord("b"): b"\b", ord("f"): b"\f", ord("v"): b"\v",
            ord("\\"): b"\\", ord('"'): b'"', ord("'"): b"'", ord("\n"): b"\n"}


class LuaParseError(ValueError):
    pass


class _Parser:
    def __init__(self, data: bytes):
        self.s = data
        self.i = 0

    def error(self, msg: str):
        line = self.s.count(b"\n", 0, self.i) + 1
        raise LuaParseError(f"{msg} at line {line}")

    def skip(self):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in b" \t\r\n":
                self.i += 1
            elif s.startswith(b"--", self.i):
                if s.startswith(b"--[[", self.i):
                    end = s.find(b"]]", self.i)
                    self.i = len(s) if end < 0 else end + 2
                else:
                    end = s.find(b"\n", self.i)
                    self.i = len(s) if end < 0 else end + 1
            else:
                break

    def peek(self) -> bytes:
        self.skip()
        return self.s[self.i:self.i + 1]

    def expect(self, ch: bytes):
        if self.peek() != ch:
            self.error(f"expected {ch!r}")
        self.i += 1

    def string(self) -> str:
        quote = self.s[self.i]
        self.i += 1
        out = bytearray()
        s = self.s
        while True:
            if self.i >= len(s):
                self.error("unterminated string")
            c = s[self.i]
            if c == quote:
                self.i += 1
                return out.decode("utf-8", errors="replace")
            if c == ord("\\"):
                nxt = s[self.i + 1]
                if nxt in _ESCAPES:
                    out += _ESCAPES[nxt]
                    self.i += 2
                elif chr(nxt).isdigit():
                    m = re.match(rb"\d{1,3}", s[self.i + 1:self.i + 4])
                    out.append(int(m.group()) & 0xFF)
                    self.i += 1 + len(m.group())
                else:
                    out.append(nxt)
                    self.i += 2
            else:
                out.append(c)
                self.i += 1

    def value(self):
        c = self.peek()
        if c in (b'"', b"'"):
            return self.string()
        if c == b"{":
            return self.table()
        m = _NUMBER.match(self.s, self.i)
        if m:
            self.i = m.end()
            text = m.group().decode()
            if text.lower().lstrip("-").startswith("0x"):
                return int(text, 16)
            num = float(text)
            return int(num) if num.is_integer() and "." not in text and "e" not in text.lower() else num
        m = _NAME.match(self.s, self.i)
        if m:
            self.i = m.end()
            word = m.group()
            if word == b"true":
                return True
            if word == b"false":
                return False
            if word == b"nil":
                return None
        self.error("unexpected value")

    def table(self):
        self.expect(b"{")
        result: dict = {}
        n = 1
        while True:
            c = self.peek()
            if c == b"}":
                self.i += 1
                break
            if c == b"[":
                self.i += 1
                key = self.value()
                self.expect(b"]")
                self.expect(b"=")
                result[key] = self.value()
            else:
                m = _NAME.match(self.s, self.i)
                after = self.s[m.end():].lstrip()[:1] if m else b""
                if m and after == b"=" and m.group() not in (b"true", b"false", b"nil"):
                    self.i = m.end()
                    self.expect(b"=")
                    result[m.group().decode()] = self.value()
                else:
                    result[n] = self.value()
                    n += 1
            if self.peek() in (b",", b";"):
                self.i += 1
        return result

    def file(self) -> dict:
        out = {}
        while self.peek():
            m = _NAME.match(self.s, self.i)
            if not m:
                self.error("expected a variable name")
            self.i = m.end()
            self.expect(b"=")
            out[m.group().decode()] = self.value()
        return out


def loads(text: str | bytes) -> dict:
    """Parse a SavedVariables file and return {global_name: value}."""
    data = text.encode("utf-8") if isinstance(text, str) else text
    return _Parser(data).file()


def load(path) -> dict:
    with open(path, "rb") as f:
        return loads(f.read())


def lua_string(s: str) -> str:
    """Quote a Python string as a Lua string literal."""
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
