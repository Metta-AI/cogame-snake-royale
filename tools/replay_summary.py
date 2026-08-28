#!/usr/bin/env python3
"""Print one strict-UTF-8 JSON object describing a snake-royale replay.

Python 3 standard library only: no Nim, no Docker, no dependencies. This is
the tool a spectator holding the bytes uses, and it is the phase-60 substitute
for the definition-of-done replay check, because this game's replay is the
starter's BINARY COWLDSNK stream rather than JSON:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                      # strict UTF-8 JSON: ok
    jq -r '.protocol, .results.reason, .results.place' /tmp/ep.json
    jq -r '[.dirs[]|select(.source=="llm")]|length, .fallbacks, (.says|length)' /tmp/ep.json

Layout (little-endian; `str` is a u32 length followed by that many bytes):

    magic "COWLDSNK"  u32 format version
    str game name     str game version   str config JSON
    u32 joins         -> u32 slot, str name, str token
    u32 turns         -> 4 direction bytes (0..3, 255 = already dead), u64 hash
    u32 chats         -> str
"""

import json
import struct
import sys

MAGIC = b"COWLDSNK"
FORMAT_VERSION = 1
SEATS = 4
DIRS = ["up", "right", "down", "left"]


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def take(self, count):
        if self.pos + count > len(self.data):
            raise ValueError("replay truncated")
        out = self.data[self.pos:self.pos + count]
        self.pos += count
        return out

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def u64(self):
        return struct.unpack("<Q", self.take(8))[0]

    def string(self):
        return self.take(self.u32())


def summarize(raw):
    reader = Reader(raw)
    if reader.take(len(MAGIC)) != MAGIC:
        raise ValueError("not a snake-royale replay: bad magic")
    version = reader.u32()
    if version != FORMAT_VERSION:
        raise ValueError("replay format version %d is not %d"
                         % (version, FORMAT_VERSION))
    game_name = reader.string().decode("utf-8")
    game_version = reader.string().decode("utf-8")
    config = json.loads(reader.string().decode("utf-8"))

    joins = []
    for _ in range(reader.u32()):
        slot = reader.u32()
        name = reader.string().decode("utf-8")
        reader.string()                       # token: never reported
        joins.append({"slot": slot, "name": name})

    turns = []
    for index in range(reader.u32()):
        bytes_ = reader.take(SEATS)
        turns.append({
            "turn": index + 1,
            "dirs": [DIRS[b] if b < len(DIRS) else "dead" for b in bytes_],
            "hash": reader.u64(),
        })

    sources = {}
    says = []
    notes_count = 0
    fallbacks = 0
    results = {}
    registers = []
    stop = None
    for _ in range(reader.u32()):
        record = reader.string().decode("utf-8")
        if not record.startswith("{"):
            continue
        node = json.loads(record)
        kind = node.get("k")
        if kind == "directive":
            sources[(node.get("turn"), node.get("slot"))] = node.get("source")
            if node.get("say"):
                says.append({"turn": node.get("turn"), "slot": node.get("slot"),
                             "text": node["say"]})
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append({"slot": node.get("slot"),
                              "kind": node.get("kind"),
                              "policy": node.get("policy"),
                              "baseline": node.get("baseline")})
        elif kind == "stop":
            stop = node
        elif kind == "result":
            results = node.get("results") or {}

    dirs = []
    for turn in turns:
        for slot in range(SEATS):
            if turn["dirs"][slot] == "dead":
                continue
            dirs.append({
                "turn": turn["turn"], "slot": slot, "dir": turn["dirs"][slot],
                "source": sources.get((turn["turn"], slot), "unknown"),
            })

    return {
        "protocol": config.get("protocol", "snake-royale/v1"),
        "gameName": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "module": config.get("module"),
        "board": config.get("board"),
        "names": [j["name"] for j in joins],
        "aliases": config.get("aliases", []),
        "colours": config.get("colours", []),
        "policyKinds": config.get("policyKinds", []),
        "spawnDeal": config.get("spawnDeal", []),
        "registers": registers,
        "turnCount": len(turns),
        "dirs": dirs,
        "says": says,
        "notes_count": notes_count,
        "fallbacks": fallbacks,
        "stop": stop,
        "results": results,
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: replay_summary.py <replay file>")
    with open(sys.argv[1], "rb") as handle:
        raw = handle.read()
    # ensure_ascii keeps the output strict-UTF-8-safe for every consumer, and
    # every string in the replay was already truncated on a RUNE boundary by
    # src/snake/directives.nim, so no lone surrogate can reach here.
    sys.stdout.write(json.dumps(summarize(raw), ensure_ascii=False,
                                sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
