#!/usr/bin/env python3
"""
proxy-hunter.py — CLI port of the cmalf.github.io/web-tools/proxy-hunter/ browser tool

Replicates the sidebar "active feeds toggle all" + protocol filter (SOCKS5, SOCKS4,
HTTP, HTTPS) + scanner functionality, but as a CLI that can be scripted and piped
into ProxyPool's config/custom-proxies.txt or zen-unlimited's EGRESS_UPSTREAMS.

Feeds (same as the browser tool's sidebar):
  - Roosterkid: SOCKS5 Raw       (GitHub)
  - Roosterkid: HTTP/HTTPS        (GitHub)
  - TheSpeedX: SOCKS5             (GitHub)
  - TheSpeedX: HTTP               (GitHub)
  - Hookzof: SOCKS5 List          (GitHub)
  - Spys.one (simulated)          (External — skipped in CLI, requires JS rendering)

Usage:
  python3 proxy-hunter.py                          # fetch all, all protocols, print TXT
  python3 proxy-hunter.py --protocol socks5       # SOCKS5 only
  python3 proxy-hunter.py --protocol socks4,http   # SOCKS4 + HTTP
  python3 proxy-hunter.py --format json           # JSON output
  python3 proxy-hunter.py --format yaml           # YAML output
  python3 proxy-hunter.py --output proxies.txt     # write to file
  python3 proxy-hunter.py --feed all              # all feeds (default)
  python3 proxy-hunter.py --feed roosterkid,thespeedx   # specific feeds only
  python3 proxy-hunter.py --timeout 10            # per-feed fetch timeout (default 15)
  python3 proxy-hunter.py --list-feeds            # list available feeds and exit
  python3 proxy-hunter.py --count-only            # print only the count

Output formats (matching the browser tool's export options):
  TXT:   socks5://1.2.3.4:1080\nsocks5://5.6.7.8:1080\n...
  JSON:  [{"protocol":"socks5","host":"1.2.3.4","port":1080},...]
  YAML:  - protocol: socks5\n  host: 1.2.3.4\n  port: 1080

Integration with ProxyPool:
  python3 proxy-hunter.py --protocol socks5 --output config/custom-proxies.txt
  # Then restart ProxyPool: it will test these proxies and use the working ones

Integration with zen-unlimited:
  python3 proxy-hunter.py --protocol socks5 --format txt | tr '\n' ',' > /tmp/egress.txt
  EGRESS_UPSTREAMS=$(cat /tmp/egress.txt) bun run src/index.ts serve
"""

from __future__ import annotations
import argparse
import json
import re
import sys
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict

# ============================================================================
# Feed definitions — the 6 feeds from the browser tool's sidebar
# ============================================================================

@dataclass
class Feed:
    id: str
    name: str
    source: str          # "GH" = GitHub, "EXT" = External
    url: str
    protocol: str        # "socks5", "socks4", "http", "https"
    parser: str           # "raw_list" or "json_list"

FEEDS = [
    Feed("roosterkid_socks5",  "Roosterkid: SOCKS5 Raw", "GH",
         "https://raw.githubusercontent.com/roosterkid/openproxylist/main/SOCKS5_RAW.txt",
         "socks5", "raw_list"),
    Feed("roosterkid_https",   "Roosterkid: HTTP/HTTPS", "GH",
         "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt",
         "https", "raw_list"),
    Feed("thespeedx_socks5",   "TheSpeedX: SOCKS5", "GH",
         "https://raw.githubusercontent.com/TheSpeedX/SOCKS-List/master/socks5.txt",
         "socks5", "raw_list"),
    Feed("thespeedx_http",     "TheSpeedX: HTTP", "GH",
         "https://raw.githubusercontent.com/TheSpeedX/SOCKS-List/master/http.txt",
         "http", "raw_list"),
    Feed("hookzof_socks5",     "Hookzof: SOCKS5 List", "GH",
         "https://raw.githubusercontent.com/Hookzof/socks5_list/main/proxy.txt",
         "socks5", "raw_list"),
    # Spys.one is an HTML page that requires JS rendering — skip in CLI mode.
    # The browser tool marks it as "(Simulated)" which suggests it scrapes HTML.
    # For the CLI, we rely on the 5 GitHub raw lists which are the bulk of the data.
]

# ============================================================================
# Proxy entry
# ============================================================================

@dataclass
class Proxy:
    protocol: str
    host: str
    port: int

    def to_url(self) -> str:
        return f"{self.protocol}://{self.host}:{self.port}"

# ============================================================================
# Fetcher + parser
# ============================================================================

IP_PORT_RE = re.compile(
    r'(?:(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})|(\[[0-9a-fA-F:]+\])):(\d{2,5})'
)

def fetch_feed(feed: Feed, timeout: int = 15) -> list[Proxy]:
    try:
        req = urllib.request.Request(
            feed.url,
            headers={
                "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) proxy-hunter/1.0",
                "Accept": "text/plain, application/json",
            }
        )
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"  [WARN] {feed.name}: fetch failed: {e}", file=sys.stderr)
        return []

    proxies: list[Proxy] = []

    if feed.parser == "raw_list":
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if "://" in line:
                proto_part, addr = line.split("://", 1)
                proto = proto_part.lower().strip()
                if proto not in ("socks5", "socks4", "http", "https"):
                    proto = feed.protocol
            else:
                addr = line
                proto = feed.protocol

            m = IP_PORT_RE.search(addr)
            if m:
                host = m.group(1) or m.group(2)
                port = int(m.group(3))
                if 1 <= port <= 65535 and host:
                    proxies.append(Proxy(protocol=proto, host=host, port=port))
    elif feed.parser == "json_list":
        try:
            data = json.loads(content)
            for entry in data:
                host = entry.get("ip") or entry.get("host") or ""
                port = entry.get("port") or 0
                if host and port:
                    proxies.append(Proxy(protocol=feed.protocol, host=str(host), port=int(port)))
        except json.JSONDecodeError:
            pass

    return proxies

# ============================================================================
# Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="CLI proxy hunter — fetches free proxies from public feeds",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--protocol", default="all",
                        help="Protocol filter: socks5, socks4, http, https, comma-separated, or 'all'")
    parser.add_argument("--format", default="txt", choices=["txt", "json", "yaml"],
                        help="Output format (default: txt)")
    parser.add_argument("--output", "-o", default=None,
                        help="Write to file (default: stdout)")
    parser.add_argument("--feed", default="all",
                        help="Feed filter: all, or comma-separated feed IDs")
    parser.add_argument("--timeout", type=int, default=15,
                        help="Per-feed fetch timeout in seconds (default: 15)")
    parser.add_argument("--no-dedupe", action="store_true",
                        help="Don't dedupe by (protocol, host, port)")
    parser.add_argument("--list-feeds", action="store_true",
                        help="List available feeds and exit")
    parser.add_argument("--count-only", action="store_true",
                        help="Print only the count, not the proxies")

    args = parser.parse_args()

    if args.list_feeds:
        print("Available feeds:")
        for f in FEEDS:
            print(f"  {f.id:25s}  [{f.source}]  {f.name}  ({f.protocol})")
        print(f"\nTotal: {len(FEEDS)} feeds")
        return

    if args.protocol == "all":
        protocols = {"socks5", "socks4", "http", "https"}
    else:
        protocols = set(p.strip().lower() for p in args.protocol.split(","))

    if args.feed == "all":
        active_feeds = FEEDS
    else:
        feed_ids = set(f.strip().lower() for f in args.feed.split(","))
        active_feeds = [f for f in FEEDS if f.id in feed_ids]
        if not active_feeds:
            print(f"ERROR: no feeds matched '{args.feed}'. Available: {[f.id for f in FEEDS]}",
                  file=sys.stderr)
            sys.exit(1)

    print(f"Fetching from {len(active_feeds)} feeds (protocols: {', '.join(sorted(protocols))})...",
          file=sys.stderr)

    all_proxies: list[Proxy] = []
    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = {pool.submit(fetch_feed, f, args.timeout): f for f in active_feeds}
        for future in as_completed(futures):
            feed = futures[future]
            try:
                fetched = future.result()
                print(f"  {feed.name}: {len(fetched)} proxies", file=sys.stderr)
                all_proxies.extend(fetched)
            except Exception as e:
                print(f"  {feed.name}: ERROR: {e}", file=sys.stderr)

    filtered = [p for p in all_proxies if p.protocol in protocols]

    if not args.no_dedupe:
        seen = set()
        deduped = []
        for p in filtered:
            key = (p.protocol, p.host, p.port)
            if key not in seen:
                seen.add(key)
                deduped.append(p)
        filtered = deduped

    print(f"\nTotal: {len(filtered)} unique proxies "
          f"(from {len(all_proxies)} raw, after protocol filter + dedupe)",
          file=sys.stderr)

    if args.count_only:
        print(len(filtered))
        return

    if args.format == "txt":
        output = "\n".join(p.to_url() for p in filtered)
    elif args.format == "json":
        output = json.dumps([asdict(p) for p in filtered], indent=2)
    elif args.format == "yaml":
        lines = []
        for p in filtered:
            lines.append(f"- protocol: {p.protocol}")
            lines.append(f"  host: {p.host}")
            lines.append(f"  port: {p.port}")
        output = "\n".join(lines)

    if args.output:
        with open(args.output, "w") as f:
            f.write(output + "\n")
        print(f"Wrote {len(filtered)} proxies to {args.output}", file=sys.stderr)
    else:
        print(output)

if __name__ == "__main__":
    main()
