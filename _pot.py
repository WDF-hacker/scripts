#!/usr/bin/env python3
"""potassium MCP stdio bridge.

用法：
  python _pot.py clients
  python _pot.py lua  <file.luau>     # 执行文件内 Luau 源码并打印 console
  python _pot.py code "<source>"
  python _pot.py raw  '<json>'        # 原样调用，调试用

MCP: streamable-http, rmcp 2.2.0, 3 个工具
  execute_script(source, pid) -> {console_cursor, targets, message}
  read_console(after_cursor, pid, limit, wait_ms)
  list_clients()
"""
import json
import sys
import time
import urllib.error
import urllib.request

URL = "http://127.0.0.1:8225/mcp"
TOKEN = "N6zk2jySEYFSLlalhGEauHljwxEMN1JixkmrQZ7Gqoo"


class Pot:
    def __init__(self, url=URL, token=TOKEN, timeout=180):
        self.url = url
        self.token = token
        self.timeout = timeout
        self.seq = 0

    def call(self, method, params, timeout=None):
        self.seq += 1
        body = json.dumps({
            "jsonrpc": "2.0",
            "id": self.seq,
            "method": method,
            "params": params or {},
        }).encode()
        req = urllib.request.Request(self.url, data=body, method="POST")
        req.add_header("Authorization", "Bearer " + self.token)
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                raw = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return {"_status": "HTTP%d" % e.code, "_raw": e.read().decode("utf-8", "replace")[:400]}
        except Exception as e:
            return {"_status": "ERR", "_raw": str(e)[:300]}

        # 可能是 SSE 帧，剥出 data: 行
        if raw.startswith("event:") or raw.startswith("data:"):
            parts = []
            for line in raw.splitlines():
                if line.startswith("data:"):
                    parts.append(line[5:].strip())
            raw = "".join(parts)
        try:
            return json.loads(raw)
        except Exception:
            return {"_status": "BADJSON", "_raw": raw[:400]}

    def tool(self, name, args, timeout=None):
        r = self.call("tools/call", {"name": name, "arguments": args}, timeout)
        if "error" in r:
            return {"_status": "RPC_ERR", "error": r["error"]}
        res = r.get("result") or {}
        # 优先结构化内容
        sc = res.get("structuredContent")
        if isinstance(sc, dict):
            return sc
        txt = []
        for c in res.get("content") or []:
            if isinstance(c, dict) and c.get("type") == "text":
                t = c.get("text") or ""
                try:
                    return json.loads(t)
                except Exception:
                    txt.append(t)
        if txt:
            return {"_status": "OK", "text": "\n".join(txt)}
        return res

    def clients(self):
        return self.tool("list_clients", {})

    def execute(self, source, pid=None):
        args = {"source": source}
        if pid:
            args["pid"] = pid
        return self.tool("execute_script", args, timeout=60)

    def read(self, cursor, wait_ms=1500, pid=None, limit=500):
        args = {"after_cursor": cursor, "wait_ms": wait_ms, "limit": limit}
        if pid:
            args["pid"] = pid
        return self.tool("read_console", args, timeout=(wait_ms / 1000.0) + 60)

    def drain(self, cursor, wait_ms=800, pid=None, max_rounds=40, sentinel="__DSH__END"):
        """轮询累积 console，按 sequence 去重，直到 sentinel 出现或连续空轮。
        返回 (texts, next_cursor)。"""
        seen = set()
        out = []
        cur = cursor
        empty = 0
        hit_end = False
        for _ in range(max_rounds):
            r = self.read(cur, wait_ms=wait_ms, pid=pid)
            ents = r.get("entries") or []
            nxt = r.get("next_cursor")
            new = 0
            for e in ents:
                if not isinstance(e, dict):
                    continue
                key = (e.get("pid"), e.get("sequence"))
                if key in seen:
                    continue
                seen.add(key)
                new += 1
                t = e.get("text")
                if isinstance(t, str):
                    out.append(t)
                    if sentinel and t.strip() == sentinel:
                        hit_end = True
            if isinstance(nxt, int):
                cur = nxt
            if hit_end:
                break
            if new == 0:
                empty += 1
                if empty >= 2:
                    break
            else:
                empty = 0
        return out, cur


def entry_text(e):
    if isinstance(e, str):
        return e
    if isinstance(e, dict):
        for k in ("text", "message", "line", "msg", "data"):
            v = e.get(k)
            if isinstance(v, str):
                return v
        return json.dumps(e, ensure_ascii=False)[:300]
    return str(e)


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 1
    p = Pot()
    cmd = a[0]

    if cmd == "clients":
        print(json.dumps(p.clients(), ensure_ascii=False, indent=1))
        return 0

    if cmd == "raw":
        print(json.dumps(p.call(a[1], json.loads(a[2]) if len(a) > 2 else {}), ensure_ascii=False)[:3000])
        return 0

    if cmd in ("lua", "code"):
        src = open(a[1], encoding="utf-8").read() if cmd == "lua" else a[1]
        r = p.execute(src)
        cur = r.get("console_cursor")
        targets = r.get("targets")
        msg = r.get("message")
        if targets:
            print("[targets] %s" % targets)
        if msg:
            print("[dispatch] %s" % msg)
        if cur is None:
            print("[no cursor] %s" % json.dumps(r, ensure_ascii=False)[:400])
            return 1
        lines, _ = p.drain(cur, wait_ms=int(a[2]) if len(a) > 2 else 800)
        for t in lines:
            print(t)
        return 0

    print("unknown cmd: %s" % cmd)
    return 1


if __name__ == "__main__":
    sys.exit(main())
