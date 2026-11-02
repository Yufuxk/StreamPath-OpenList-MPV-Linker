"""刮削准确性报告：结构断言 + 独立 oracle 对照。

用法：
  python tools/film_scrape_accuracy_report.py <report.json> <manifest.json> [expected.json]

report.json 由 tools/film_scrape_accuracy_probe.dart 生成。
未提供 expected.json 时，按“条目容器”生成 oracle（目录名 -> TMDB 搜索首条）并对照。
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from collections import Counter, defaultdict

HOST = "api.tmdb.org"


class CREDENTIAL(ctypes.Structure):
    _fields_ = [
        ("Flags", wt.DWORD),
        ("Type", wt.DWORD),
        ("TargetName", wt.LPWSTR),
        ("Comment", wt.LPWSTR),
        ("LastWritten", wt.FILETIME),
        ("CredentialBlobSize", wt.DWORD),
        ("CredentialBlob", ctypes.POINTER(ctypes.c_byte)),
        ("Persist", wt.DWORD),
        ("AttributeCount", wt.DWORD),
        ("Attributes", ctypes.c_void_p),
        ("TargetAlias", wt.LPWSTR),
        ("UserName", wt.LPWSTR),
    ]


def read_token():
    advapi = ctypes.WinDLL("advapi32")
    pcred = ctypes.POINTER(CREDENTIAL)()
    if not advapi.CredReadW(wt.LPCWSTR("StreamPath/tmdb"), 1, 0, ctypes.byref(pcred)):
        raise SystemExit("TMDB credential is not readable")
    blob = ctypes.string_at(pcred.contents.CredentialBlob, pcred.contents.CredentialBlobSize)
    token = blob.decode("utf-8").strip()
    advapi.CredFree(pcred)
    return token


_ORACLE = {}


def tmdb(token, path, query):
    key = path + "?" + urllib.parse.urlencode(sorted(query.items()))
    if key in _ORACLE:
        return _ORACLE[key]
    url = "https://%s/3/%s?%s" % (HOST, path, urllib.parse.urlencode(query))
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(request, timeout=25) as response:
        value = json.loads(response.read().decode("utf-8"))
    _ORACLE[key] = value
    return value


def clean_container(name):
    value = re.sub(r"^(?:19|20)\d{2}\s*[-–—]\s*", "", name.strip())
    value = re.sub(r"^\d{1,2}[.、]\s*", "", value)
    value = value.replace("《", " ").replace("》", " ").replace("「", " ").replace("」", " ")
    years = re.findall(r"(?<!\d)((?:19|20)\d{2})(?!\d)", value)
    year = int(years[-1]) if years else None
    value = re.sub(r"(?<!\d)(?:19|20)\d{2}(?!\d)", " ", value)
    value = re.sub(r"[._]+", " ", value)
    value = re.sub(r"\s+", " ", value).strip(" -–—.:：")
    return value, year


def container_of(row, root_path):
    parent = row["parent"].replace("\\", "/")
    if parent == root_path:
        return None
    prefix = root_path + "/"
    if not parent.startswith(prefix):
        return None
    rest = parent[len(prefix):]
    if not rest:
        return None
    return prefix + rest.split("/")[0]


VERSION = re.compile(
    r"(?<![a-z0-9])(?:blu[ ._-]?ray|blue[ ._-]?ray|bd[ ._-]?remux|remux|bdrip|brrip|bd|uhd|"
    r"web[ ._-]?(?:dl|rip)|hdtv|dvdrip|dvd|cam|telesync|(?:480|576|720|1080|1440|2160|4320)[pi]|"
    r"[248]k|\d{3,4}x\d{3,4}|[hx][ ._-]?26[45]|avc|hevc|av1|xvid|divx|flac|aac|ac3|eac3|ddp|"
    r"truehd|dts(?:[ ._-]?hd)?|pcm|lpcm|hdr10\+?|hdr|dovi|dolby[ ._-]?vision|hi10p|10bit|8bit)"
    r"(?![a-z0-9])",
    re.IGNORECASE,
)
EDITION = re.compile(
    r"(?<![a-z0-9])(?:director'?s[ ._-]+cut|extended(?:[ ._-]+cut)?|unrated|uncut|"
    r"theatrical(?:[ ._-]+cut)?|remastered|imax|final[ ._-]+cut|(?:part|pt|cd|disc)[ ._-]*\d{1,2})"
    r"(?![a-z0-9])",
    re.IGNORECASE,
)


def identity_key(name):
    value = VERSION.sub(" ", name)
    value = EDITION.sub(" ", value)
    return re.sub(r"[\s._:\-–—'’\"()\[\]{}!?，。：、！？」「『』《》·・~～〜]+", "", value).lower()


def main():
    report_path = sys.argv[1]
    manifest_path = sys.argv[2]
    expected_path = sys.argv[3] if len(sys.argv) > 3 else None
    with open(report_path, encoding="utf-8") as handle:
        report = json.load(handle)
    with open(manifest_path, encoding="utf-8") as handle:
        manifest = json.load(handle)
    roots = {run["rootId"]: run["path"] for run in report["runs"]}
    rows = report["resources"]
    by_root = defaultdict(list)
    for row in rows:
        by_root[row["rootId"]].append(row)
    problems = []
    notes = []
    for root_id, run in [(run["rootId"], run) for run in report["runs"]]:
        items = by_root[root_id]
        unbound = [r for r in items if r["workId"] is None]
        by_type = Counter(r["type"] for r in items)
        print(f"== root {run['path']} ({run['type']}) files={len(items)} {dict(by_type)}")
        print(f"   processed={run['processed']} total={run['total']} status={run['status']} error={run['error'] or run['scrapeError']}")
        print(f"   unbound={len(unbound)}")
        if unbound:
            for row in unbound[:40]:
                print(f"     UNBOUND {row['path']}")
            if len(unbound) > 40:
                print(f"     ... {len(unbound) - 40} more")
            if expected_path is None:
                problems.append((run["path"], "unbound", [r["path"] for r in unbound]))
        if run["type"] == "tv":
            missing = [r for r in items if r["season"] is None or r["episode"] is None]
            print(f"   missing episode={len(missing)}")
            for row in missing[:20]:
                print(f"     NOEP {row['path']}")
            if missing and expected_path is None:
                problems.append((run["path"], "missingEpisode", [r["path"] for r in missing[:20]]))
    # 容器 / 作品 一致性
    containers = defaultdict(set)
    works = defaultdict(set)
    episodes = defaultdict(set)
    for row in rows:
        root_path = roots.get(row["rootId"], "")
        container = container_of(row, root_path)
        # 直接位于根下的条目没有容器，不参与容器一致性判断。
        if container is None:
            continue
        key = (row["rootId"], container)
        if row["workId"] is not None:
            containers[key].add((row["workId"], row["tmdbId"], row["title"]))
            works[(row["workId"], row["tmdbId"], row["title"])].add(key)
        episodes[key].add((row["season"], row["episode"]))
    for key, values in sorted(containers.items(), key=lambda kv: str(kv[0])):
        if len(values) > 1:
            print(f"   MIXED CONTAINER {key[1]} -> {sorted(values)}")
            problems.append((key[1], "mixedContainer", sorted(values)))
    for work, keys in sorted(works.items(), key=lambda kv: str(kv[0])):
        if len(keys) > 1:
            labels = sorted(identity_key(str(k[1]).split("/")[-1]) for k in keys)
            print(f"   MULTI CONTAINER {work[1]} {work[2]} -> {sorted(k[1] for k in keys)}")
            if len(set(labels)) > 1:
                problems.append((work[2], "multiContainer", sorted(k[1] for k in keys)))
            else:
                notes.append(("legitVersions", work[2]))
    # 与真值 / oracle 对照
    if expected_path:
        with open(expected_path, encoding="utf-8") as handle:
            expected = {row["path"]: row for row in json.load(handle)}
        wrong = []
        missing = []
        for path, truth in expected.items():
            actual = next((r for r in rows if r["path"] == path), None)
            if actual is None:
                missing.append(path)
                continue
            if actual["tmdbId"] != truth["tmdbId"]:
                wrong.append((path, truth, actual))
            elif truth.get("season") is not None and (
                actual["season"] != truth["season"] or actual["episode"] != truth["episode"]
            ):
                wrong.append((path, truth, actual))
        print(f"== expected files={len(expected)} missing={len(missing)} wrong={len(wrong)}")
        for path, truth, actual in wrong[:40]:
            print(
                f"   WRONG {path}\n     expected tmdb={truth['tmdbId']} s={truth.get('season')} e={truth.get('episode')}"
                f"\n     actual   tmdb={actual['tmdbId']} {actual['title']} s={actual['season']} e={actual['episode']}"
            )
        for path in missing[:20]:
            print(f"   MISSING {path}")
        problems.append(("expected", "wrong", [(w[0], w[1]["tmdbId"], w[2]["tmdbId"]) for w in wrong]))
        problems.append(("expected", "missing", missing))
    else:
        token = read_token()
        disagreements = []
        seen = set()
        for key, values in sorted(containers.items(), key=lambda kv: str(kv[0])):
            container = key[1]
            label = str(container).split("/")[-1]
            title, year = clean_container(label)
            if not title or title in seen:
                continue
            seen.add(title)
            media_type = "tv" if any(
                r["type"] == "tv" for r in rows if r["rootId"] == key[0]
            ) else "movie"
            query = {"query": title, "language": "zh-CN"}
            try:
                data = tmdb(token, "search/" + media_type, query)
            except Exception as error:  # noqa: BLE001
                notes.append(("oracleError", title, str(error)))
                continue
            results = data.get("results") or []
            if not results:
                notes.append(("oracleNoResult", title))
                continue
            top = results[0]
            oracle_id = top["id"]
            actual_ids = {value[1] for value in values}
            if oracle_id not in actual_ids:
                disagreements.append((title, year, sorted(actual_ids), oracle_id, top.get("name") or top.get("title")))
        print(f"== oracle disagreements={len(disagreements)}")
        for title, year, actual, oracle_id, oracle_title in disagreements:
            print(f"   DIFF container={title} year={year} actual={actual} oracle={oracle_id} {oracle_title}")
        problems.append(("oracle", "disagree", disagreements))
    print("== notes")
    for note in notes[:20]:
        print("  ", note)
    print(f"== problems={sum(1 for p in problems if p[2])}")
    for name, kind, value in problems:
        if value:
            print(f"   {name} / {kind}: {len(value) if isinstance(value, (list, set)) else value}")
    return 0 if not any(p[2] for p in problems) else 1


if __name__ == "__main__":
    sys.exit(main())
