#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
import hashlib
from pathlib import Path
from typing import Dict, List, Optional, Tuple


ROOT_DIR = Path(__file__).resolve().parents[2]
STATE_DIR = ROOT_DIR / "autonomy" / "state"
OFFSET_FILE = STATE_DIR / "telegram-offset.json"
APPROVAL_DIR = STATE_DIR / "telegram-approvals"
CONTROL_FILE = STATE_DIR / "emergency-stop.json"
CONSENSUS_DIR = STATE_DIR / "consensus"
WATCHDOG_FILE = STATE_DIR / "telegram-watchdog.json"

AGENTS = {"gpt", "claude", "gemini", "grok"}
SERVICE_BY_AGENT = {
    "gpt": "openclaw-gpt",
    "claude": "openclaw-claude",
    "gemini": "openclaw-gemini",
    "grok": "openclaw-grok",
}


def getenv_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def getenv_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None or not raw.strip():
        return default
    try:
        return int(raw.strip())
    except Exception:
        return default


def parse_id_set(raw: str) -> set:
    out = set()
    for part in raw.split(","):
        v = part.strip()
        if not v:
            continue
        out.add(v)
    return out


BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
ALLOWED_CHAT_IDS = parse_id_set(os.getenv("TELEGRAM_ALLOWED_CHAT_IDS", ""))
POLL_TIMEOUT_SECONDS = int(os.getenv("TELEGRAM_POLL_TIMEOUT_SECONDS", "30"))
COMMAND_TIMEOUT_SECONDS = int(os.getenv("TELEGRAM_COMMAND_TIMEOUT_SECONDS", "900"))
MAX_OUTPUT_CHARS = int(os.getenv("TELEGRAM_MAX_OUTPUT_CHARS", "3500"))
ENABLE_E2E_MERGE = getenv_bool("TELEGRAM_ENABLE_E2E_MERGE", False)
LEADER_ONLY_MODE = getenv_bool("TELEGRAM_LEADER_ONLY_MODE", True)
MINIMAL_COMMAND_MODE = getenv_bool("TELEGRAM_MINIMAL_COMMAND_MODE", True)
REQUIRE_APPROVAL_COMMANDS = {
    x.strip().lower()
    for x in os.getenv("TELEGRAM_REQUIRE_APPROVAL_COMMANDS", "pr,e2e_merge").split(",")
    if x.strip()
}
AUTO_REQUEST_ON_BLOCKER = getenv_bool("TELEGRAM_AUTO_REQUEST_ON_BLOCKER", True)
PAUSE_DEV_WHEN_PENDING = getenv_bool("TELEGRAM_PAUSE_DEV_WHEN_PENDING", True)
AUTO_PLAN_REVIEW_ON_PENDING = getenv_bool("TELEGRAM_AUTO_PLAN_REVIEW_ON_PENDING", True)
PLAN_REVIEW_REPO = os.getenv("TELEGRAM_PLAN_REVIEW_REPO", "workdirs/gpt").strip()
AGENT_CONSENSUS_REQUIRED = getenv_bool("TELEGRAM_AGENT_CONSENSUS_REQUIRED", True)
AGENT_CONSENSUS_MIN = max(1, min(4, getenv_int("TELEGRAM_AGENT_CONSENSUS_MIN", 3)))
WATCHDOG_ENABLED = getenv_bool("TELEGRAM_WATCHDOG_ENABLED", True)
WATCHDOG_INTERVAL_SECONDS = max(30, getenv_int("TELEGRAM_WATCHDOG_INTERVAL_SECONDS", 300))
WATCHDOG_TIMEOUT_SECONDS = max(60, getenv_int("TELEGRAM_WATCHDOG_TIMEOUT_SECONDS", 240))
WATCHDOG_ALERT_COOLDOWN_SECONDS = max(60, getenv_int("TELEGRAM_WATCHDOG_ALERT_COOLDOWN_SECONDS", 600))
WATCHDOG_PROMPT = os.getenv("TELEGRAM_WATCHDOG_PROMPT", "한 문장으로 hello")
WATCHDOG_CHECK_MOLTBOOK = getenv_bool("TELEGRAM_WATCHDOG_CHECK_MOLTBOOK", True)
DEV_BLOCK_COMMAND_KEYS = {"commit", "pr", "e2e", "e2e_merge"}
LEADER_AGENT = os.getenv("AGENT_LEADER", "gemini").strip().lower()
STOP_COMMANDS = {"/stop", "/emergency_stop", "/panic"}
RESUME_COMMANDS = {"/resume", "/continue"}
MINIMAL_ALLOWED_COMMANDS = {
    "/help",
    "/start",
    "/pending",
    "/approve",
    "/reject",
    "/status",
    "/stop",
    "/emergency_stop",
    "/panic",
    "/resume",
    "/continue",
}
ALLOWED_WHEN_STOPPED = {
    "/help",
    "/start",
    "/pending",
    "/reject",
    "/status",
    "/stop",
    "/emergency_stop",
    "/panic",
    "/resume",
    "/continue",
}

if not BOT_TOKEN:
    print("TELEGRAM_BOT_TOKEN is required", file=sys.stderr)
    sys.exit(2)

if not ALLOWED_CHAT_IDS:
    print("TELEGRAM_ALLOWED_CHAT_IDS is required (comma-separated)", file=sys.stderr)
    sys.exit(2)

STATE_DIR.mkdir(parents=True, exist_ok=True)
APPROVAL_DIR.mkdir(parents=True, exist_ok=True)
CONSENSUS_DIR.mkdir(parents=True, exist_ok=True)
API_BASE = f"https://api.telegram.org/bot{BOT_TOKEN}"


def tg_api(method: str, payload: Dict) -> Dict:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        f"{API_BASE}/{method}",
        data=data,
        method="POST",
        headers={"content-type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    decoded = json.loads(body)
    if not decoded.get("ok"):
        raise RuntimeError(f"telegram api error: {decoded}")
    return decoded


def send_message(chat_id: str, text: str) -> None:
    chunks = chunk_text(text, MAX_OUTPUT_CHARS)
    for c in chunks:
        tg_api("sendMessage", {"chat_id": chat_id, "text": c, "disable_web_page_preview": True})


def chunk_text(text: str, max_chars: int) -> List[str]:
    if len(text) <= max_chars:
        return [text]
    parts: List[str] = []
    rest = text
    while len(rest) > max_chars:
        idx = rest.rfind("\n", 0, max_chars)
        if idx < 0:
            idx = max_chars
        parts.append(rest[:idx].rstrip())
        rest = rest[idx:].lstrip()
    if rest:
        parts.append(rest)
    return parts


def load_offset() -> int:
    if not OFFSET_FILE.exists():
        return 0
    try:
        data = json.loads(OFFSET_FILE.read_text(encoding="utf-8"))
        return int(data.get("offset", 0))
    except Exception:
        return 0


def save_offset(offset: int) -> None:
    OFFSET_FILE.write_text(json.dumps({"offset": offset}, ensure_ascii=True), encoding="utf-8")


def load_control_state() -> Dict:
    if not CONTROL_FILE.exists():
        return {"emergency_stop": False}
    try:
        data = json.loads(CONTROL_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return {"emergency_stop": False}
        data.setdefault("emergency_stop", False)
        return data
    except Exception:
        return {"emergency_stop": False}


def save_control_state(data: Dict) -> None:
    CONTROL_FILE.write_text(json.dumps(data, ensure_ascii=True, indent=2), encoding="utf-8")


def is_emergency_stopped() -> bool:
    return bool(load_control_state().get("emergency_stop", False))


def set_emergency_stop(active: bool, chat_id: str, reason: str) -> Dict:
    cur = load_control_state()
    cur["emergency_stop"] = bool(active)
    cur["updated_at"] = now_utc()
    cur["updated_by_chat_id"] = str(chat_id)
    if active:
        cur["reason"] = reason.strip() if reason.strip() else "manual_emergency_stop"
    else:
        cur["resume_reason"] = reason.strip() if reason.strip() else "manual_resume"
    save_control_state(cur)
    return cur


def load_watchdog_state() -> Dict:
    if not WATCHDOG_FILE.exists():
        return {"alert_active": False, "last_alert_at": 0, "last_failure_hash": ""}
    try:
        data = json.loads(WATCHDOG_FILE.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return {"alert_active": False, "last_alert_at": 0, "last_failure_hash": ""}
        data.setdefault("alert_active", False)
        data.setdefault("last_alert_at", 0)
        data.setdefault("last_failure_hash", "")
        return data
    except Exception:
        return {"alert_active": False, "last_alert_at": 0, "last_failure_hash": ""}


def save_watchdog_state(data: Dict) -> None:
    WATCHDOG_FILE.write_text(json.dumps(data, ensure_ascii=True, indent=2), encoding="utf-8")


def run_cmd(args: List[str], timeout: Optional[int] = None) -> Tuple[int, str]:
    env = os.environ.copy()
    proc = subprocess.run(
        args,
        cwd=str(ROOT_DIR),
        capture_output=True,
        text=True,
        timeout=timeout or COMMAND_TIMEOUT_SECONDS,
        env=env,
    )
    out = (proc.stdout or "") + (proc.stderr or "")
    out = out.strip()
    if len(out) > 15000:
        out = out[:15000] + "\n...[truncated]"
    return proc.returncode, out


def safe_rel_path(raw: str) -> Optional[Path]:
    p = Path(raw)
    if p.is_absolute():
        cand = p
    else:
        cand = ROOT_DIR / p
    try:
        resolved = cand.resolve()
    except Exception:
        return None
    try:
        resolved.relative_to(ROOT_DIR)
    except ValueError:
        return None
    return resolved


def parse_command(text: str) -> Tuple[str, List[str]]:
    parts = text.strip().split()
    if not parts:
        return "", []
    cmd = parts[0].split("@")[0].lower()
    return cmd, parts[1:]


def command_key(cmd: str) -> str:
    return cmd.lstrip("/").strip().lower()


def requires_approval(cmd: str) -> bool:
    return command_key(cmd) in REQUIRE_APPROVAL_COMMANDS


def now_utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def approval_path(req_id: str) -> Path:
    return APPROVAL_DIR / f"{req_id}.json"


def create_approval(chat_id: str, text: str) -> str:
    req_id = f"req_{int(time.time())}_{uuid.uuid4().hex[:8]}"
    payload = {
        "id": req_id,
        "status": "pending",
        "created_at": now_utc(),
        "chat_id": str(chat_id),
        "command_text": text,
        "plan_review_triggered": False,
    }
    approval_path(req_id).write_text(json.dumps(payload, ensure_ascii=True, indent=2), encoding="utf-8")
    return req_id


def load_approval(req_id: str) -> Optional[Dict]:
    p = approval_path(req_id)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def save_approval(data: Dict) -> None:
    req_id = str(data.get("id", "")).strip()
    if not req_id:
        raise ValueError("approval missing id")
    approval_path(req_id).write_text(json.dumps(data, ensure_ascii=True, indent=2), encoding="utf-8")


def list_pending_approvals(chat_id: str) -> List[Dict]:
    out: List[Dict] = []
    for p in sorted(APPROVAL_DIR.glob("req_*.json")):
        try:
            data = json.loads(p.read_text(encoding="utf-8"))
        except Exception:
            continue
        if str(data.get("status", "")) != "pending":
            continue
        if str(data.get("chat_id", "")) != str(chat_id):
            continue
        out.append(data)
    return out


def trigger_plan_review_for_request(chat_id: str, req: Dict, reason: str) -> None:
    if not AUTO_PLAN_REVIEW_ON_PENDING:
        return
    if req.get("plan_review_triggered"):
        return

    req_id = str(req.get("id", "")).strip()
    if not req_id:
        return

    send_message(
        chat_id,
        (
            "Development is paused until human decision.\n"
            f"Starting plan review cycle for {req_id}..."
        ),
    )
    code, out = run_cmd(
        [
            "./scripts/autonomy/plan-review-cycle.sh",
            "--reason",
            f"pending_request:{req_id}:{reason}",
            "--repo",
            PLAN_REVIEW_REPO,
        ],
        timeout=1200,
    )
    req["plan_review_triggered"] = True
    req["plan_review_triggered_at"] = now_utc()
    req["plan_review_exit_code"] = code
    req["plan_review_output_preview"] = (out or "")[:600]
    save_approval(req)
    prefix = "PASS" if code == 0 else "FAIL"
    send_message(chat_id, f"[plan_review:{req_id}] {prefix}\n\n{out or '(no output)'}")


def find_json_object(text: str) -> Optional[Dict]:
    raw = (text or "").strip()
    if not raw:
        return None
    try:
        obj = json.loads(raw)
        if isinstance(obj, dict):
            return obj
    except Exception:
        pass

    m = re.search(r"\{[\s\S]*\}", raw)
    if not m:
        return None
    snippet = m.group(0)
    try:
        obj = json.loads(snippet)
        if isinstance(obj, dict):
            return obj
    except Exception:
        return None
    return None


def has_pending_similar_request(chat_id: str, reason: str, detail: str) -> bool:
    detail_norm = (detail or "").strip().lower()
    for req in list_pending_approvals(chat_id):
        if str(req.get("reason", "")).strip().lower() != reason.strip().lower():
            continue
        req_detail = str(req.get("agent_request_reason", "")).strip().lower()
        if req_detail and req_detail == detail_norm:
            return True
        if not req_detail and detail_norm:
            continue
        if not detail_norm and not req_detail:
            return True
    return False


def run_agent_consensus(chat_id: str, reason_detail: str, original_command_text: str, source_output: str) -> Tuple[bool, Dict]:
    run_id = f"consensus_{int(time.time())}_{uuid.uuid4().hex[:8]}"
    votes: List[Dict] = []
    yes_count = 0
    error_agents: List[str] = []
    output_excerpt = (source_output or "")[:900]

    for agent in ["gpt", "claude", "gemini", "grok"]:
        prompt = (
            f"You are '{agent}' participating in a human-intervention vote.\n"
            f"Leader agent: {LEADER_AGENT}\n"
            "Goal: decide whether human intervention is truly required NOW.\n"
            "Respond with ONLY JSON:\n"
            "{\n"
            '  "agent":"<agent>",\n'
            '  "decision":"approve|reject",\n'
            '  "requires_human": true|false,\n'
            '  "confidence": 0-100,\n'
            '  "reason":"one sentence"\n'
            "}\n\n"
            f"Trigger detail: {reason_detail}\n"
            f"Original command: {original_command_text}\n"
            f"Observed output excerpt:\n{output_excerpt}\n"
        )
        service = SERVICE_BY_AGENT[agent]
        code, out = run_cmd(["./scripts/prompt-one-agent.sh", service, prompt], timeout=240)
        vote: Dict = {"agent": agent, "ok": code == 0, "raw": (out or "")[:1200]}
        parsed = find_json_object(out or "")

        if code != 0 or not parsed:
            vote["decision"] = "error"
            vote["requires_human"] = False
            vote["confidence"] = 0
            vote["reason"] = "vote_failed"
            error_agents.append(agent)
            votes.append(vote)
            continue

        decision = str(parsed.get("decision", "")).strip().lower()
        requires_human = bool(parsed.get("requires_human", False))
        yes = requires_human or decision in {"approve", "yes", "request_human"}
        vote["decision"] = decision or "unknown"
        vote["requires_human"] = requires_human
        vote["confidence"] = int(parsed.get("confidence", 0) or 0)
        vote["reason"] = str(parsed.get("reason", "")).strip()[:300]
        vote["yes"] = yes
        if yes:
            yes_count += 1
        votes.append(vote)

    passed = yes_count >= AGENT_CONSENSUS_MIN
    result = {
        "run_id": run_id,
        "created_at": now_utc(),
        "reason_detail": reason_detail,
        "command_text": original_command_text,
        "consensus_min": AGENT_CONSENSUS_MIN,
        "yes_count": yes_count,
        "passed": passed,
        "error_agents": error_agents,
        "votes": votes,
    }
    out_file = CONSENSUS_DIR / f"{run_id}.json"
    out_file.write_text(json.dumps(result, ensure_ascii=True, indent=2), encoding="utf-8")
    result["artifact"] = str(out_file)
    return passed, result


def detect_human_blocker(text: str) -> Optional[str]:
    t = (text or "").lower()
    patterns = [
        (r"invalid username or token|authentication failed|incorrect api key|invalid api key|invalid x-api-key", "credentials_invalid"),
        (r"permission denied|forbidden|insufficient permission|requires .* permission|permissions\.push=false", "permission_denied"),
        (r"rate limit|too many requests|retry_after|429", "rate_limited"),
        (r"insufficient_quota|quota exceeded|exceeded your current quota|billing hard limit|out of credits|credit balance is too low|payment required|402", "provider_quota_exhausted"),
        (r"context length|maximum context length|token limit exceeded", "provider_token_limit"),
        (r"model overloaded|server is overloaded|service unavailable|503", "provider_unavailable"),
        (r"not found \(likely token lacks merge permission", "merge_permission_missing"),
        (r"must register|claim|verify-email|owner.*email|pending_claim", "ownership_verification_required"),
        (r"telegra[m]?_bot_token is required|telegram_allowed_chat_ids is required|missing .* required", "missing_required_config"),
    ]
    for pat, reason in patterns:
        if re.search(pat, t):
            return reason
    return None


def extract_agent_human_request_reason(text: str) -> Optional[str]:
    if not text:
        return None
    patterns = [
        r"\[HUMAN_REQUEST\]\s*[:\-]?\s*(.+)",
        r"\[HUMAN_APPROVAL\]\s*[:\-]?\s*(.+)",
        r"HUMAN_REQUEST\s*[:\-]\s*(.+)",
        r"HUMAN_APPROVAL\s*[:\-]\s*(.+)",
    ]
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        for pat in patterns:
            m = re.search(pat, line, flags=re.IGNORECASE)
            if not m:
                continue
            reason = (m.group(1) or "").strip()
            if not reason:
                reason = "agent_consensus_requested_human_input"
            return reason[:280]
    return None


def maybe_request_human_on_agent_signal(chat_id: str, original_command_text: str, output: str) -> Optional[str]:
    reason_detail = extract_agent_human_request_reason(output)
    if not reason_detail:
        return None
    if has_pending_similar_request(chat_id, "agent_consensus_request", reason_detail):
        return None

    consensus_run_id = ""
    consensus_artifact = ""
    consensus_yes = 0

    if AGENT_CONSENSUS_REQUIRED:
        send_message(
            chat_id,
            (
                "Agent-level human request detected.\n"
                f"Running consensus vote ({AGENT_CONSENSUS_MIN}/4 required)..."
            ),
        )
        consensus_passed, consensus = run_agent_consensus(
            chat_id,
            reason_detail,
            original_command_text,
            output,
        )
        yes_count = int(consensus.get("yes_count", 0))
        consensus_yes = yes_count
        consensus_run_id = str(consensus.get("run_id", ""))
        artifact = str(consensus.get("artifact", ""))
        consensus_artifact = artifact

        # If one or more agents cannot vote at all, escalate immediately as system-degradation.
        error_agents = consensus.get("error_agents", []) or []
        if error_agents and not consensus_passed:
            req_id = create_approval(chat_id, original_command_text)
            req = load_approval(req_id) or {}
            req["reason"] = "agent_unavailable_during_consensus"
            req["agent_request_reason"] = reason_detail
            req["consensus_run_id"] = consensus.get("run_id")
            req["consensus_artifact"] = artifact
            req["error_agents"] = error_agents
            req["note"] = "Immediate escalation: one or more agents failed during consensus."
            save_approval(req)
            send_message(
                chat_id,
                (
                    "Human intervention required (agent unavailable during consensus).\n"
                    f"request_id: {req_id}\n"
                    f"detail: {reason_detail}\n"
                    f"error_agents: {', '.join(error_agents)}\n"
                    f"consensus_yes: {yes_count}/4\n"
                    f"artifact: {artifact}\n\n"
                    f"Approve: /approve {req_id}\n"
                    f"Reject: /reject {req_id}"
                ),
            )
            trigger_plan_review_for_request(chat_id, req, "agent_unavailable_during_consensus")
            return req_id

        if not consensus_passed:
            send_message(
                chat_id,
                (
                    "Consensus rejected human intervention request.\n"
                    f"detail: {reason_detail}\n"
                    f"votes: {yes_count}/4 (required: {AGENT_CONSENSUS_MIN})\n"
                    f"artifact: {artifact}"
                ),
            )
            return None

    req_id = create_approval(chat_id, original_command_text)
    req = load_approval(req_id) or {}
    req["reason"] = "agent_consensus_request"
    req["agent_request_reason"] = reason_detail
    if AGENT_CONSENSUS_REQUIRED:
        req["consensus_required"] = True
        req["consensus_min"] = AGENT_CONSENSUS_MIN
        req["consensus_yes"] = consensus_yes
        if consensus_run_id:
            req["consensus_run_id"] = consensus_run_id
        if consensus_artifact:
            req["consensus_artifact"] = consensus_artifact
    req["note"] = "Auto-created from explicit [HUMAN_REQUEST] marker in agent output."
    save_approval(req)
    send_message(
        chat_id,
        (
            "Human intervention requested by agent consensus.\n"
            f"request_id: {req_id}\n"
            f"detail: {reason_detail}\n"
            f"command: {original_command_text}\n\n"
            f"Approve: /approve {req_id}\n"
            f"Reject: /reject {req_id}"
        ),
    )
    trigger_plan_review_for_request(chat_id, req, "agent_consensus_request")
    return req_id


def maybe_request_human_on_blocker(chat_id: str, original_command_text: str, output: str) -> Optional[str]:
    if not AUTO_REQUEST_ON_BLOCKER:
        return None
    reason = detect_human_blocker(output)
    if not reason:
        return None

    req_id = create_approval(chat_id, original_command_text)
    req = load_approval(req_id) or {}
    req["reason"] = reason
    req["note"] = "Auto-created due to blocker detection on failed command."
    save_approval(req)
    send_message(
        chat_id,
        (
            "Human intervention required.\n"
            f"request_id: {req_id}\n"
            f"reason: {reason}\n"
            f"command: {original_command_text}\n\n"
            f"After fixing, run: /approve {req_id}\n"
            f"Or reject: /reject {req_id}"
        ),
    )
    trigger_plan_review_for_request(chat_id, req, reason)
    return req_id


def report_result(chat_id: str, label: str, code: int, output: str, original_command_text: str) -> None:
    prefix = "PASS" if code == 0 else "FAIL"
    send_message(chat_id, f"[{label}] {prefix}\n\n{output or '(no output)'}")
    req_id = maybe_request_human_on_agent_signal(chat_id, original_command_text, output or "")
    if code != 0:
        if not req_id:
            maybe_request_human_on_blocker(chat_id, original_command_text, output or "")


def primary_chat_id() -> str:
    return sorted(ALLOWED_CHAT_IDS)[0]


def has_pending_watchdog_request(chat_id: str) -> bool:
    for req in list_pending_approvals(chat_id):
        if str(req.get("reason", "")).startswith("watchdog_"):
            return True
    return False


def run_watchdog_tick() -> None:
    if not WATCHDOG_ENABLED:
        return
    if is_emergency_stopped():
        return

    chat_id = primary_chat_id()
    args = ["./scripts/autonomy/test-all-agents.sh", "--prompt", WATCHDOG_PROMPT]
    if not WATCHDOG_CHECK_MOLTBOOK:
        args.append("--skip-moltbook")

    code, out = run_cmd(args, timeout=WATCHDOG_TIMEOUT_SECONDS)
    state = load_watchdog_state()
    now_ts = int(time.time())

    if code == 0:
        if state.get("alert_active"):
            send_message(chat_id, "[watchdog] RECOVERED\nAll agents are healthy again.")
        state["alert_active"] = False
        state["last_ok_at"] = now_utc()
        state["last_failure_hash"] = ""
        save_watchdog_state(state)
        return

    normalized = re.sub(r"\s+", " ", (out or "").strip().lower())[:1500]
    failure_hash = hashlib.sha1(normalized.encode("utf-8", errors="ignore")).hexdigest()
    reason = detect_human_blocker(out or "") or "agent_watchdog_failed"
    req_reason = f"watchdog_{reason}"

    if (
        state.get("alert_active")
        and state.get("last_failure_hash") == failure_hash
        and now_ts - int(state.get("last_alert_at", 0) or 0) < WATCHDOG_ALERT_COOLDOWN_SECONDS
    ):
        state["last_seen_at"] = now_utc()
        save_watchdog_state(state)
        return

    if has_pending_watchdog_request(chat_id):
        state["alert_active"] = True
        state["last_alert_at"] = now_ts
        state["last_failure_hash"] = failure_hash
        state["last_reason"] = req_reason
        state["last_seen_at"] = now_utc()
        save_watchdog_state(state)
        return

    req_id = create_approval(chat_id, "/status")
    req = load_approval(req_id) or {}
    req["reason"] = req_reason
    req["note"] = "Auto-created by watchdog due to agent health failure."
    req["watchdog_failure_hash"] = failure_hash
    req["watchdog_excerpt"] = (out or "")[:1200]
    save_approval(req)

    send_message(
        chat_id,
        (
            "[watchdog] Human intervention required.\n"
            f"request_id: {req_id}\n"
            f"reason: {req_reason}\n\n"
            f"Approve: /approve {req_id}\n"
            f"Reject: /reject {req_id}\n\n"
            f"excerpt:\n{(out or '')[:1000]}"
        ),
    )
    trigger_plan_review_for_request(chat_id, req, req_reason)

    state["alert_active"] = True
    state["last_alert_at"] = now_ts
    state["last_failure_hash"] = failure_hash
    state["last_reason"] = req_reason
    state["last_seen_at"] = now_utc()
    save_watchdog_state(state)


def help_text() -> str:
    if MINIMAL_COMMAND_MODE:
        return (
            "Commands (minimal mode):\n"
            "/help\n"
            "/pending\n"
            "/approve <request_id>\n"
            "/reject <request_id>\n"
            "/status\n"
            "/emergency_stop [reason]\n"
            "/resume [reason]\n"
            "\n"
            "All dev commands are disabled in minimal mode.\n"
            "Agents should request human intervention via [HUMAN_REQUEST] marker.\n"
            "\n"
            f"approval-required: {', '.join(sorted(REQUIRE_APPROVAL_COMMANDS)) or '(none)'}\n"
            f"auto-request-on-blocker: {AUTO_REQUEST_ON_BLOCKER}\n"
            f"pause-dev-when-pending: {PAUSE_DEV_WHEN_PENDING}\n"
            f"auto-plan-review-on-pending: {AUTO_PLAN_REVIEW_ON_PENDING}\n"
            f"leader-agent: {LEADER_AGENT}\n"
            f"leader-only-mode: {LEADER_ONLY_MODE}\n"
            f"minimal-command-mode: {MINIMAL_COMMAND_MODE}\n"
            f"emergency-stop-active: {is_emergency_stopped()}\n"
            f"agent-consensus: {AGENT_CONSENSUS_REQUIRED} (min={AGENT_CONSENSUS_MIN}/4)\n"
            f"watchdog: {WATCHDOG_ENABLED} (interval={WATCHDOG_INTERVAL_SECONDS}s)\n"
            "\n"
            "agent-consensus-trigger marker:\n"
            "- [HUMAN_REQUEST]: <reason>\n"
            "- [HUMAN_APPROVAL]: <reason>\n"
        )

    if LEADER_ONLY_MODE:
        return (
            "Commands:\n"
            "/help\n"
            "/pending\n"
            "/approve <request_id>\n"
            "/reject <request_id>\n"
            "/status\n"
            f"/ask <prompt>  (leader: {LEADER_AGENT})\n"
            f"/commit <task_file>  (leader: {LEADER_AGENT})\n"
            f"/pr [base_branch] [title...]  (leader: {LEADER_AGENT})\n"
            f"/e2e  (forced leader-only: {LEADER_AGENT})\n"
            f"/e2e_merge  (forced leader-only: {LEADER_AGENT}, enabled only if TELEGRAM_ENABLE_E2E_MERGE=true)\n"
            "/plan_review  (manual planning-only cycle)\n"
            "\n"
            f"approval-required: {', '.join(sorted(REQUIRE_APPROVAL_COMMANDS)) or '(none)'}\n"
            f"auto-request-on-blocker: {AUTO_REQUEST_ON_BLOCKER}\n"
            f"pause-dev-when-pending: {PAUSE_DEV_WHEN_PENDING}\n"
            f"auto-plan-review-on-pending: {AUTO_PLAN_REVIEW_ON_PENDING}\n"
            f"leader-agent: {LEADER_AGENT}\n"
            f"leader-only-mode: {LEADER_ONLY_MODE}\n"
            f"minimal-command-mode: {MINIMAL_COMMAND_MODE}\n"
            f"emergency-stop-active: {is_emergency_stopped()}\n"
            f"agent-consensus: {AGENT_CONSENSUS_REQUIRED} (min={AGENT_CONSENSUS_MIN}/4)\n"
            f"watchdog: {WATCHDOG_ENABLED} (interval={WATCHDOG_INTERVAL_SECONDS}s)\n"
            "\n"
            "agent-consensus-trigger marker:\n"
            "- [HUMAN_REQUEST]: <reason>\n"
            "- [HUMAN_APPROVAL]: <reason>\n"
        )

    return (
        "Commands:\n"
        "/help\n"
        "/pending\n"
        "/approve <request_id>\n"
        "/reject <request_id>\n"
        "/status\n"
        "/ask <agent> <prompt>\n"
        "/commit <agent> <task_file>\n"
        "/pr <agent> [base_branch] [title...]\n"
        "/e2e [agents_csv]  (merge disabled by default)\n"
        "/e2e_merge [agents_csv]  (enabled only if TELEGRAM_ENABLE_E2E_MERGE=true)\n"
        "/plan_review  (manual planning-only cycle)\n"
        "\n"
        f"approval-required: {', '.join(sorted(REQUIRE_APPROVAL_COMMANDS)) or '(none)'}\n"
        f"auto-request-on-blocker: {AUTO_REQUEST_ON_BLOCKER}\n"
        f"pause-dev-when-pending: {PAUSE_DEV_WHEN_PENDING}\n"
        f"auto-plan-review-on-pending: {AUTO_PLAN_REVIEW_ON_PENDING}\n"
        f"leader-agent: {LEADER_AGENT}\n"
        f"leader-only-mode: {LEADER_ONLY_MODE}\n"
        f"minimal-command-mode: {MINIMAL_COMMAND_MODE}\n"
        f"emergency-stop-active: {is_emergency_stopped()}\n"
        f"agent-consensus: {AGENT_CONSENSUS_REQUIRED} (min={AGENT_CONSENSUS_MIN}/4)\n"
        f"watchdog: {WATCHDOG_ENABLED} (interval={WATCHDOG_INTERVAL_SECONDS}s)\n"
        "\n"
        "agent-consensus-trigger marker:\n"
        "- [HUMAN_REQUEST]: <reason>\n"
        "- [HUMAN_APPROVAL]: <reason>\n"
        "\n"
        "agents: gpt, claude, gemini, grok"
    )


def handle_command(chat_id: str, text: str, bypass_approval: bool = False) -> None:
    cmd, args = parse_command(text)
    if not cmd:
        return
    cmd_key = command_key(cmd)

    if cmd in {"/start", "/help"}:
        send_message(chat_id, help_text())
        return

    if cmd in STOP_COMMANDS:
        reason = " ".join(args).strip() if args else "manual_emergency_stop"
        state = set_emergency_stop(True, chat_id, reason)
        send_message(
            chat_id,
            (
                "Emergency stop ACTIVATED.\n"
                f"reason: {state.get('reason')}\n"
                f"updated_at: {state.get('updated_at')}\n"
                "Use /resume [reason] to continue."
            ),
        )
        return

    if cmd in RESUME_COMMANDS:
        reason = " ".join(args).strip() if args else "manual_resume"
        state = set_emergency_stop(False, chat_id, reason)
        send_message(
            chat_id,
            (
                "Emergency stop CLEARED.\n"
                f"resume_reason: {state.get('resume_reason', reason)}\n"
                f"updated_at: {state.get('updated_at')}"
            ),
        )
        return

    if MINIMAL_COMMAND_MODE and cmd not in MINIMAL_ALLOWED_COMMANDS:
        send_message(
            chat_id,
            (
                "This command is disabled in minimal mode.\n"
                "Allowed: /help, /pending, /approve, /reject, /status, /emergency_stop, /resume"
            ),
        )
        return

    if is_emergency_stopped() and cmd not in ALLOWED_WHEN_STOPPED:
        send_message(
            chat_id,
            "Emergency stop is active. Allowed now: /help, /pending, /reject, /status, /resume",
        )
        return

    if cmd == "/plan_review":
        send_message(chat_id, "Running planning-only review cycle...")
        code, out = run_cmd(
            ["./scripts/autonomy/plan-review-cycle.sh", "--reason", "manual_command", "--repo", PLAN_REVIEW_REPO],
            timeout=1200,
        )
        report_result(chat_id, "plan_review", code, out, text)
        return

    if cmd == "/pending":
        rows = list_pending_approvals(chat_id)
        if not rows:
            send_message(chat_id, "No pending approvals.")
            return
        lines = ["Pending approvals:"]
        for r in rows[:20]:
            lines.append(
                f"- {r.get('id')} | created={r.get('created_at')} | cmd={r.get('command_text')}"
            )
        send_message(chat_id, "\n".join(lines))
        return

    if cmd == "/reject":
        if len(args) != 1:
            send_message(chat_id, "Usage: /reject <request_id>")
            return
        req_id = args[0].strip()
        req = load_approval(req_id)
        if not req:
            send_message(chat_id, f"Request not found: {req_id}")
            return
        if str(req.get("chat_id")) != str(chat_id):
            send_message(chat_id, "Unauthorized for this request.")
            return
        if req.get("status") != "pending":
            send_message(chat_id, f"Request already {req.get('status')}: {req_id}")
            return
        req["status"] = "rejected"
        req["resolved_at"] = now_utc()
        req["resolved_by_chat_id"] = str(chat_id)
        save_approval(req)
        send_message(chat_id, f"Rejected: {req_id}")
        return

    if cmd == "/approve":
        if len(args) != 1:
            send_message(chat_id, "Usage: /approve <request_id>")
            return
        if is_emergency_stopped():
            send_message(chat_id, "Emergency stop is active. Run /resume first, then /approve.")
            return
        req_id = args[0].strip()
        req = load_approval(req_id)
        if not req:
            send_message(chat_id, f"Request not found: {req_id}")
            return
        if str(req.get("chat_id")) != str(chat_id):
            send_message(chat_id, "Unauthorized for this request.")
            return
        if req.get("status") != "pending":
            send_message(chat_id, f"Request already {req.get('status')}: {req_id}")
            return
        req["status"] = "approved"
        req["resolved_at"] = now_utc()
        req["resolved_by_chat_id"] = str(chat_id)
        save_approval(req)
        original_cmd = str(req.get("command_text", "")).strip()
        send_message(chat_id, f"Approved: {req_id}\nExecuting: {original_cmd}")
        handle_command(chat_id, original_cmd, bypass_approval=True)
        return

    if requires_approval(cmd) and not bypass_approval:
        req_id = create_approval(chat_id, text)
        req = load_approval(req_id) or {}
        req["reason"] = "pre_execution_approval_required"
        save_approval(req)
        send_message(
            chat_id,
            (
                "Approval required for this command.\n"
                f"request_id: {req_id}\n"
                f"command: {text}\n\n"
                f"Approve: /approve {req_id}\n"
                f"Reject: /reject {req_id}"
            ),
        )
        trigger_plan_review_for_request(chat_id, req, "pre_execution_approval_required")
        return

    if PAUSE_DEV_WHEN_PENDING and cmd_key in DEV_BLOCK_COMMAND_KEYS and not bypass_approval:
        pending = list_pending_approvals(chat_id)
        if pending:
            req = pending[0]
            req_id = str(req.get("id", "unknown"))
            reason = str(req.get("reason", "pending_human_intervention"))
            send_message(
                chat_id,
                (
                    "Development commands are paused while approval is pending.\n"
                    f"pending request: {req_id}\n"
                    f"reason: {reason}\n"
                    "Use /approve or /reject first."
                ),
            )
            trigger_plan_review_for_request(chat_id, req, reason)
            return

    if cmd == "/status":
        send_message(chat_id, "Running health check...")
        code, out = run_cmd(
            ["./scripts/autonomy/test-all-agents.sh", "--prompt", "한 문장으로 hello"]
        )
        report_result(chat_id, "status", code, out, text)
        return

    if cmd == "/ask":
        if LEADER_ONLY_MODE:
            if len(args) < 1:
                send_message(chat_id, f"Usage: /ask <prompt>  (leader: {LEADER_AGENT})")
                return
            if args[0].lower() in AGENTS:
                if args[0].lower() != LEADER_AGENT:
                    send_message(chat_id, f"Leader-only mode: only {LEADER_AGENT} is allowed for /ask.")
                    return
                if len(args) < 2:
                    send_message(chat_id, f"Usage: /ask <prompt>  (leader: {LEADER_AGENT})")
                    return
                agent = LEADER_AGENT
                prompt = text.split(None, 2)[2]
            else:
                agent = LEADER_AGENT
                prompt = text.split(None, 1)[1]
        else:
            if len(args) < 2:
                send_message(chat_id, "Usage: /ask <agent> <prompt>")
                return
            agent = args[0].lower()
            if agent not in AGENTS:
                send_message(chat_id, f"Unknown agent: {agent}")
                return
            prompt = text.split(None, 2)[2]
        service = SERVICE_BY_AGENT[agent]
        send_message(chat_id, f"Querying {agent}...")
        code, out = run_cmd(["./scripts/prompt-one-agent.sh", service, prompt], timeout=240)
        report_result(chat_id, f"ask:{agent}", code, out, text)
        return

    if cmd == "/commit":
        if LEADER_ONLY_MODE:
            if len(args) == 1:
                agent = LEADER_AGENT
                task_raw = args[0]
            elif len(args) == 2 and args[0].lower() in AGENTS:
                if args[0].lower() != LEADER_AGENT:
                    send_message(chat_id, f"Leader-only mode: only {LEADER_AGENT} is allowed for /commit.")
                    return
                agent = LEADER_AGENT
                task_raw = args[1]
            else:
                send_message(chat_id, f"Usage: /commit <task_file>  (leader: {LEADER_AGENT})")
                return
        else:
            if len(args) != 2:
                send_message(chat_id, "Usage: /commit <agent> <task_file>")
                return
            agent = args[0].lower()
            if agent not in AGENTS:
                send_message(chat_id, f"Unknown agent: {agent}")
                return
            task_raw = args[1]
        task_path = safe_rel_path(task_raw)
        if not task_path or not task_path.exists():
            send_message(chat_id, f"Invalid task_file: {task_raw}")
            return
        send_message(chat_id, f"Running commit for {agent}...")
        code, out = run_cmd(
            ["./scripts/autonomy/agent-dev-commit.sh", agent, str(task_path)],
            timeout=600,
        )
        report_result(chat_id, f"commit:{agent}", code, out, text)
        return

    if cmd == "/pr":
        if LEADER_ONLY_MODE:
            agent = LEADER_AGENT
            rem = args
            if rem and rem[0].lower() in AGENTS:
                if rem[0].lower() != LEADER_AGENT:
                    send_message(chat_id, f"Leader-only mode: only {LEADER_AGENT} is allowed for /pr.")
                    return
                rem = rem[1:]
            base = "main"
            title = ""
            if len(rem) >= 1:
                base = rem[0]
            if len(rem) >= 2:
                title = " ".join(rem[1:])
        else:
            if len(args) < 1:
                send_message(chat_id, "Usage: /pr <agent> [base_branch] [title...]")
                return
            agent = args[0].lower()
            if agent not in AGENTS:
                send_message(chat_id, f"Unknown agent: {agent}")
                return
            base = "main"
            title = ""
            if len(args) >= 2:
                base = args[1]
            if len(args) >= 3:
                title = " ".join(args[2:])
        pr_args = ["./scripts/autonomy/create-pr-if-approved.sh", agent, base]
        if title:
            pr_args.append(title)
        send_message(chat_id, f"Creating PR for {agent} (base={base})...")
        code, out = run_cmd(pr_args, timeout=900)
        report_result(chat_id, f"pr:{agent}", code, out, text)
        return

    if cmd in {"/e2e", "/e2e_merge"}:
        if LEADER_ONLY_MODE:
            agents = [LEADER_AGENT]
        else:
            agents_csv = args[0] if args else "gpt,claude,gemini,grok"
            agents = [a.strip().lower() for a in agents_csv.split(",") if a.strip()]
        bad = [a for a in agents if a not in AGENTS]
        if bad:
            send_message(chat_id, f"Unknown agents: {', '.join(bad)}")
            return
        if not agents:
            send_message(chat_id, "No agents provided")
            return

        e2e_args = [
            "./scripts/autonomy/test-collab-main-flow.sh",
            "--agents",
            " ".join(agents),
            "--review-retries",
            "5",
            "--review-retry-sleep",
            "8",
            "--commit-retries",
            "5",
            "--commit-retry-sleep",
            "8",
        ]
        if cmd == "/e2e":
            e2e_args.append("--no-merge")
        else:
            if not ENABLE_E2E_MERGE:
                send_message(
                    chat_id,
                    "e2e merge is disabled. Set TELEGRAM_ENABLE_E2E_MERGE=true to allow /e2e_merge.",
                )
                return
        send_message(chat_id, f"Running E2E ({'merge' if cmd == '/e2e_merge' else 'no-merge'})...")
        code, out = run_cmd(e2e_args, timeout=1800)
        report_result(chat_id, "e2e", code, out, text)
        return

    send_message(chat_id, "Unknown command. Use /help")


def main() -> int:
    offset = load_offset()
    last_watchdog_check = 0.0
    print("telegram-controller started")
    print(f"allowed chats: {sorted(ALLOWED_CHAT_IDS)}")
    print(f"leader-agent: {LEADER_AGENT}")
    print(f"leader-only-mode: {LEADER_ONLY_MODE}")
    print(f"minimal-command-mode: {MINIMAL_COMMAND_MODE}")
    print(f"emergency-stop-active: {is_emergency_stopped()}")
    print(f"agent-consensus-required: {AGENT_CONSENSUS_REQUIRED} (min={AGENT_CONSENSUS_MIN}/4)")
    print(
        f"watchdog-enabled: {WATCHDOG_ENABLED} "
        f"(interval={WATCHDOG_INTERVAL_SECONDS}s, timeout={WATCHDOG_TIMEOUT_SECONDS}s)"
    )

    while True:
        try:
            updates = tg_api(
                "getUpdates",
                {
                    "timeout": POLL_TIMEOUT_SECONDS,
                    "offset": offset,
                    "allowed_updates": ["message"],
                },
            ).get("result", [])

            for upd in updates:
                update_id = int(upd.get("update_id", 0))
                offset = max(offset, update_id + 1)
                save_offset(offset)

                msg = upd.get("message") or {}
                chat = msg.get("chat") or {}
                chat_id = str(chat.get("id", ""))
                text = msg.get("text", "")
                if not text:
                    continue
                if chat_id not in ALLOWED_CHAT_IDS:
                    try:
                        send_message(chat_id, "Unauthorized chat.")
                    except Exception:
                        pass
                    continue
                handle_command(chat_id, text)

            if WATCHDOG_ENABLED:
                now_ts = time.time()
                if now_ts - last_watchdog_check >= WATCHDOG_INTERVAL_SECONDS:
                    run_watchdog_tick()
                    last_watchdog_check = now_ts

        except urllib.error.URLError as e:
            print(f"network error: {e}", file=sys.stderr)
            time.sleep(3)
        except KeyboardInterrupt:
            print("stopped")
            return 0
        except Exception:
            traceback.print_exc()
            time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
