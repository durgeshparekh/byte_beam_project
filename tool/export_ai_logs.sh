#!/usr/bin/env bash
# Export raw Claude Code session transcripts to ai-logs/*.md (deliverable 3),
# plus the git history to ai-logs/git-log.md.
# Uncurated: user turns, assistant turns, tool calls and tool results verbatim.
#
#   tool/export_ai_logs.sh                      # sessions run from this project
#   tool/export_ai_logs.sh --src DIR            # also read this transcript dir
#   tool/export_ai_logs.sh --match byte_beam    # only sessions mentioning this
#
# --match exists because Claude Code groups transcripts by the directory it was
# launched from. Sessions for this assignment that were started from a parent
# directory land in that directory's group alongside unrelated work, and only
# this project's conversations belong in this repo.
set -euo pipefail
cd "$(dirname "$0")/.."

SRCS=()
MATCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src)   SRCS+=("$2"); shift 2 ;;
    --match) MATCH="$2";   shift 2 ;;
    *) echo "unknown argument: $1"; exit 2 ;;
  esac
done

if [ ${#SRCS[@]} -eq 0 ]; then
  # Claude Code slugs the launch directory; underscores may or may not be folded.
  for SLUG in "$(pwd | sed 's|/|-|g')" "$(pwd | sed 's|[/_]|-|g')"; do
    [ -d "$HOME/.claude/projects/$SLUG" ] && SRCS+=("$HOME/.claude/projects/$SLUG")
  done
fi
[ ${#SRCS[@]} -eq 0 ] && { echo "no transcript directories found"; exit 1; }

mkdir -p ai-logs
# Git history next to the transcripts, oldest first, so each commit can be read
# against the conversation that produced it. Written before the transcript step
# because that step exits non-zero when it refuses a session.
{
  echo "# Git log"
  echo
  echo '```'
  git log --reverse --date=iso --stat
  echo '```'
} > ai-logs/git-log.md
echo "ai-logs/git-log.md"
python3 - "$MATCH" "${SRCS[@]}" <<'PY'
import json, re, sys, pathlib

match, srcs = sys.argv[1], [pathlib.Path(p) for p in sys.argv[2:]]
out = pathlib.Path("ai-logs")
CAP = 4000  # tool results are truncated; everything else is verbatim

# The logs are committed and shared, and tool results are copied verbatim, so a
# credential that ever reached a terminal would be published. Fail closed: a
# session containing one of these is not written at all. Not curation — nothing
# is removed silently; the operator redacts the source and re-runs.
SECRETS = re.compile("|".join([
    r"sk-ant-[A-Za-z0-9_-]{20,}",                      # Anthropic
    r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}",                # OpenAI
    r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}",
    r"AKIA[0-9A-Z]{16}",                               # AWS access key id
    r"AIza[0-9A-Za-z_-]{35}",                          # Google API key
    r"xox[abprs]-[A-Za-z0-9-]{10,}",                   # Slack
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----",
]))

def blocks(content):
    """Yields (kind, text) for each renderable block of a message."""
    if isinstance(content, str):
        yield "text", content
        return
    for b in content or []:
        t = b.get("type")
        if t == "text":
            yield "text", b.get("text", "")
        elif t == "thinking":
            yield "thinking", b.get("thinking", "")
        elif t == "tool_use":
            yield "tool", f"{b.get('name')}\n{json.dumps(b.get('input', {}), indent=2)}"
        elif t == "tool_result":
            c = b.get("content")
            c = c if isinstance(c, str) else json.dumps(c, indent=2)
            yield "result", c[:CAP] + ("\n… truncated" if len(c) > CAP else "")

written = blocked = 0
for src in srcs:
    for f in sorted(src.glob("*.jsonl")):
        raw_text = f.read_text(errors="replace")
        if match and match not in raw_text:
            continue

        lines, first = [], None
        for raw in raw_text.splitlines():
            try:
                o = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if o.get("type") not in ("user", "assistant"):
                continue
            first = first or o.get("timestamp", "")
            who = "User" if o["type"] == "user" else "Claude"
            lines.append(f"\n### {who} — {o.get('timestamp','')}\n")
            for kind, text in blocks(o.get("message", {}).get("content")):
                if not text.strip():
                    continue
                if kind == "text":
                    lines.append(text + "\n")
                elif kind == "thinking":
                    lines.append(f"<details><summary>thinking</summary>\n\n{text}\n\n</details>\n")
                else:
                    lines.append(f"**{kind}**\n```\n{text}\n```\n")
        if not lines:
            continue
        body = f"# Session {f.stem}\n_{first}_\n" + "".join(lines)
        hits = sorted({m.group(0)[:12] + "…" for m in SECRETS.finditer(body)})
        if hits:
            print(f"refusing {f.name}: possible secrets {hits}", file=sys.stderr)
            blocked += 1
            continue
        dest = out / f"{first[:10]}-{f.stem[:8]}.md"
        dest.write_text(body)
        print(dest)
        written += 1

print(f"{written} session(s) exported", file=sys.stderr)
sys.exit(1 if blocked else 0)
PY
