#!/usr/bin/env python3
"""Slide-style can-i report. Layout follows Lucas Käldström's Cedar talks:
Can P do A on R?, RequestInfo + UserInfo, authorizer Allow/Deny, rakkess-style verbs.
"""
from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import tempfile
from pathlib import Path

EUID = re.compile(r'^(.+)::"(.*)"$')
ID_SPLIT = re.compile(r'@id\("([^"]+)"\)')


def esc(value: object) -> str:
    return html.escape("" if value is None else str(value), quote=True)


def read_text(path: str) -> str:
    if not path:
        return ""
    p = Path(path)
    if not p.is_file():
        return ""
    return p.read_text(encoding="utf-8")


def parse_euid(euid: str) -> tuple[str, str]:
    m = EUID.match(euid or "")
    if not m:
        return "", euid or ""
    return m.group(1), m.group(2)


def parse_determining(log: str) -> list[str]:
    names: list[str] = []
    grab = False
    for line in (log or "").splitlines():
        low = line.lower()
        if "due to the following policies:" in low:
            grab = True
            continue
        if not grab:
            continue
        stripped = line.strip()
        if not stripped:
            break
        if stripped.lower().startswith("note:"):
            break
        if stripped in ("ALLOW", "DENY"):
            break
        names.append(stripped.rstrip(","))
    return names


def policy_bodies(blob: str) -> dict[str, str]:
    parts = ID_SPLIT.split(blob or "")
    out: dict[str, str] = {}
    it = iter(parts[1:])
    for name, body in zip(it, it):
        out[name] = body.strip()
    return out


def load_json(path: str, default):
    raw = read_text(path)
    if not raw.strip():
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return default


def write_atomic(path: str, content: str) -> None:
    target = Path(path)
    parent = target.parent
    if not parent.is_dir():
        raise FileNotFoundError(f"report directory does not exist: {parent}")
    fd, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        fd = -1
        os.replace(temporary, target)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def decision_word(decision: str) -> str:
    return "Allow" if decision == "ALLOW" else "Deny" if decision == "DENY" else decision or "—"


def render(meta: dict) -> str:
    decision = (meta.get("decision") or "").upper()
    word = decision_word(decision)
    kind = "allow" if decision == "ALLOW" else "deny" if decision == "DENY" else "unknown"
    p = meta.get("principal") or {}
    a = meta.get("action") or {}
    r = meta.get("resource") or {}
    ns = meta.get("namespace") or ""
    apigroup = meta.get("apiGroup") if meta.get("apiGroup") is not None else ""
    obj = meta.get("objectName") or ""
    mode = meta.get("mode") or "cedar"
    ctx = meta.get("context") or "default"
    included = int(meta.get("included") or 0)
    skipped = int(meta.get("skipped") or 0)
    included_names = meta.get("includedNames") or []
    determining = meta.get("determining") or []
    policies = meta.get("policies") or ""
    entities = meta.get("entities") or []
    matrix = meta.get("matrix") or []
    log = meta.get("authorizeLog") or ""
    bodies = policy_bodies(policies)
    p_type, p_id = parse_euid(p.get("euid") or "")
    a_type, a_id = parse_euid(a.get("euid") or "")
    r_type, r_id = parse_euid(r.get("euid") or "")
    p_label = p.get("label") or p_id
    a_label = a.get("label") or a_id
    r_label = r.get("label") or r_id
    ag_show = "(core)" if apigroup == "" and mode == "k8s" else (apigroup or "—")
    ns_show = ns or ("—" if mode == "k8s" else "—")
    det_note = ""
    if not determining:
        det_note = "default deny — no policy applied to this request" if decision == "DENY" else "no determining policy named"
    det_pills = "".join(
        f'<span class="pill">{esc(n)}</span>' for n in determining
    ) or f'<span class="muted">{esc(det_note)}</span>'
    det_blocks = []
    for name in determining:
        src = bodies.get(name, "")
        if src:
            det_blocks.append(
                f'<article class="policy"><h3>@id("{esc(name)}")</h3><pre>{esc(src)}</pre></article>'
            )
        else:
            det_blocks.append(
                f'<article class="policy"><h3>@id("{esc(name)}")</h3><p class="muted">Source not in the concatenated set.</p></article>'
            )
    if not det_blocks:
        det_blocks.append('<p class="muted">Cedar default is deny unless a permit applies (and no forbid wins).</p>')
    cr_list = "".join(f"<li>{esc(n)}</li>" for n in included_names) or "<li class='muted'>none</li>"
    verb_cells = ""
    if matrix:
        heads = "".join(f"<th>{esc(row.get('verb'))}</th>" for row in matrix)
        cells = []
        for row in matrix:
            d = (row.get("decision") or "").upper()
            if d == "ALLOW":
                mark, cls = "✔", "ok"
            elif d == "DENY":
                mark, cls = "✖", "no"
            else:
                mark, cls = "?", "err"
            cells.append(f'<td class="{cls}">{mark}</td>')
        verb_cells = f"""
        <section class="panel">
          <h2>What can P do on R?</h2>
          <p class="lede">Same principal and resource, other verbs. Cedar against Policy CRs — not RBAC.</p>
          <div class="table-wrap">
            <table class="rakkess">
              <thead><tr><th>resource</th>{heads}</tr></thead>
              <tbody><tr><th>{esc(r_label)}</th>{''.join(cells)}</tr></tbody>
            </table>
          </div>
        </section>"""
    parent_rows = []
    for ent in entities:
        uid = (ent.get("uid") or {})
        parents = ent.get("parents") or []
        if not parents:
            continue
        child = f'{uid.get("type")}::"{uid.get("id")}"'
        for par in parents:
            parent = f'{par.get("type")}::"{par.get("id")}"'
            parent_rows.append(
                f"<tr><td>{esc(child)}</td><td>in</td><td>{esc(parent)}</td></tr>"
            )
    dag = ""
    if parent_rows:
        dag = f"""
        <section class="panel">
          <h2>Entity hierarchy</h2>
          <p class="lede">Parents from the entities file (User in Group, and so on). Stub entities have none.</p>
          <div class="table-wrap">
            <table class="rakkess">
              <thead><tr><th>entity</th><th></th><th>parent</th></tr></thead>
              <tbody>{''.join(parent_rows)}</tbody>
            </table>
          </div>
        </section>"""
    log_block = f"<pre class='log'>{esc(log.strip())}</pre>" if log.strip() else "<p class='muted'>No cedar log.</p>"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Can P do A on R? — {esc(word)}</title>
<style>
  :root {{
    --bg: #070b14;
    --bg2: #0c1220;
    --card: #121a2b;
    --line: #243049;
    --text: #f4f7fb;
    --muted: #8b9bb4;
    --teal: #2dd4bf;
    --allow: #4ade80;
    --deny: #f87171;
    --warn: #fbbf24;
  }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; background: var(--bg); color: var(--text);
    font-family: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif; }}
  body {{ min-height: 100vh; }}
  .slide {{
    max-width: 1120px; margin: 0 auto; padding: 36px 28px 64px;
  }}
  header.top {{
    display: flex; justify-content: space-between; align-items: baseline; gap: 16px;
    margin-bottom: 28px;
  }}
  header.top h1 {{
    font-size: clamp(28px, 4vw, 44px); font-weight: 650; letter-spacing: -0.03em;
    margin: 0; line-height: 1.1;
  }}
  header.top h1 em {{ font-style: normal; color: var(--teal); }}
  .meta {{ color: var(--muted); font-size: 13px; text-align: right; line-height: 1.5; }}
  .parc {{
    display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px; margin: 8px 0 22px;
  }}
  .box {{
    background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 18px 18px 16px; min-height: 148px;
  }}
  .box .k {{
    font-size: 12px; font-weight: 700; letter-spacing: 0.18em; color: var(--teal);
  }}
  .box h2 {{
    margin: 10px 0 6px; font-size: clamp(22px, 3vw, 32px); font-weight: 650;
    letter-spacing: -0.03em; word-break: break-word;
  }}
  .box code, code {{
    font-family: "IBM Plex Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
    font-size: 12px; color: var(--muted);
  }}
  .box .sub {{ margin-top: 10px; color: var(--muted); font-size: 12px; line-height: 1.45; }}
  .decision {{
    display: flex; flex-direction: column; align-items: center; justify-content: center;
    border-radius: 16px; padding: 22px 16px 20px; margin: 6px 0 26px;
    border: 1px solid var(--line); text-align: center;
  }}
  .decision.allow {{ background: #0d2718; border-color: #1d6b3a; }}
  .decision.deny {{ background: #2a1216; border-color: #7f1d1d; }}
  .decision .word {{
    font-size: clamp(40px, 7vw, 72px); font-weight: 750; letter-spacing: -0.04em;
    line-height: 1;
  }}
  .decision.allow .word {{ color: var(--allow); }}
  .decision.deny .word {{ color: var(--deny); }}
  .decision .why {{ margin-top: 12px; color: var(--muted); font-size: 14px; }}
  .pills {{ display: flex; flex-wrap: wrap; gap: 8px; justify-content: center; margin-top: 10px; }}
  .pill {{
    background: #1a2438; border: 1px solid var(--line); border-radius: 999px;
    padding: 4px 12px; font-size: 13px; font-family: ui-monospace, Menlo, monospace;
  }}
  .pipe {{
    display: grid; grid-template-columns: 1fr auto 1fr auto 1fr auto 1fr;
    gap: 8px; align-items: stretch; margin: 0 0 28px;
  }}
  .stage {{
    background: var(--bg2); border: 1px solid var(--line); border-radius: 10px;
    padding: 10px 8px; text-align: center; font-size: 12px; color: var(--muted);
  }}
  .stage strong {{ display: block; color: var(--text); font-size: 13px; margin-bottom: 2px; }}
  .stage.on {{ border-color: var(--teal); color: var(--text); background: #10212a; }}
  .stage.on.allow {{ border-color: var(--allow); background: #0d2718; }}
  .stage.on.deny {{ border-color: var(--deny); background: #2a1216; }}
  .arrow {{ color: var(--muted); display: flex; align-items: center; font-size: 18px; }}
  .cols {{ display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin-bottom: 22px; }}
  .panel {{
    background: var(--card); border: 1px solid var(--line); border-radius: 14px;
    padding: 18px 20px 20px; margin-bottom: 16px;
  }}
  .panel h2, .cols h2 {{
    margin: 0 0 6px; font-size: 16px; font-weight: 650;
  }}
  .lede {{ color: var(--muted); font-size: 13px; line-height: 1.5; margin: 0 0 14px; }}
  dl.kv {{ display: grid; grid-template-columns: 120px 1fr; gap: 6px 12px; margin: 0; font-size: 14px; }}
  dl.kv dt {{ color: var(--muted); }}
  dl.kv dd {{ margin: 0; word-break: break-word; }}
  table.rakkess {{
    width: 100%; border-collapse: collapse; font-size: 14px;
  }}
  table.rakkess th, table.rakkess td {{
    border: 1px solid var(--line); padding: 8px 10px; text-align: center;
  }}
  table.rakkess th:first-child, table.rakkess td:first-child {{ text-align: left; }}
  table.rakkess td.ok {{ color: var(--allow); font-weight: 700; }}
  table.rakkess td.no {{ color: var(--deny); font-weight: 700; }}
  table.rakkess td.err {{ color: var(--warn); font-weight: 700; }}
  .table-wrap {{ overflow-x: auto; }}
  pre {{
    background: #070b14; border: 1px solid var(--line); border-radius: 10px;
    padding: 12px 14px; overflow-x: auto; font-size: 12.5px; line-height: 1.45;
    font-family: "IBM Plex Mono", ui-monospace, Menlo, monospace; color: #d6e4f5;
  }}
  pre.log {{ max-height: 240px; color: var(--muted); }}
  .policy {{ margin-bottom: 12px; }}
  .policy h3 {{ margin: 0 0 8px; font-size: 13px; color: var(--teal); font-family: ui-monospace, Menlo, monospace; }}
  footer {{
    margin-top: 8px; color: var(--muted); font-size: 12px; line-height: 1.55;
  }}
  .muted {{ color: var(--muted); }}
  ul.crs {{ margin: 0; padding-left: 18px; color: var(--text); }}
  @media (max-width: 800px) {{
    .parc, .cols, .pipe {{ grid-template-columns: 1fr; }}
    .arrow {{ display: none; }}
  }}
  @media print {{
    body {{ background: #fff; color: #111; }}
    .box, .panel, .decision, .stage {{ break-inside: avoid; }}
  }}
</style>
</head>
<body>
  <div class="slide">
    <header class="top">
      <h1>Can <em>P</em> do <em>A</em> on <em>R</em>?</h1>
      <div class="meta">
        Cedar authorizer · k9s plugin<br>
        context {esc(ctx)} · {esc(mode)} request<br>
        {included} policies · {skipped} skipped
      </div>
    </header>

    <section class="parc">
      <article class="box">
        <div class="k">P · PRINCIPAL</div>
        <h2>{esc(p_label)}</h2>
        <code>{esc(p.get("euid") or "")}</code>
        <div class="sub">UserInfo<br>type {esc(p_type or "—")}</div>
      </article>
      <article class="box">
        <div class="k">A · ACTION</div>
        <h2>{esc(a_label)}</h2>
        <code>{esc(a.get("euid") or "")}</code>
        <div class="sub">RequestInfo.verb</div>
      </article>
      <article class="box">
        <div class="k">R · RESOURCE</div>
        <h2>{esc(r_label)}</h2>
        <code>{esc(r.get("euid") or "")}</code>
        <div class="sub">namespace {esc(ns_show)} · apiGroup {esc(ag_show)}{(" · name " + esc(obj)) if obj else ""}</div>
      </article>
    </section>

    <section class="decision {kind}">
      <div class="word">{esc(word)}</div>
      <div class="why">Authorizer decision · forbid wins · default deny</div>
      <div class="pills">{det_pills}</div>
    </section>

    <section class="pipe" aria-label="API server path">
      <div class="stage"><strong>Authentication</strong>UserInfo</div>
      <div class="arrow">→</div>
      <div class="stage on {kind}"><strong>Authorizer</strong>Cedar · {esc(word)}</div>
      <div class="arrow">→</div>
      <div class="stage"><strong>Admission</strong>body not in this check</div>
      <div class="arrow">→</div>
      <div class="stage"><strong>Storage</strong>etcd</div>
    </section>

    <section class="cols">
      <div class="panel">
        <h2>RequestInfo</h2>
        <p class="lede">Kubernetes authorization sees metadata from the URL, not the object body.</p>
        <dl class="kv">
          <dt>verb</dt><dd>{esc(a_label)}</dd>
          <dt>resource</dt><dd>{esc(r_label)}</dd>
          <dt>namespace</dt><dd>{esc(ns or "—")}</dd>
          <dt>apiGroup</dt><dd>{esc(ag_show)}</dd>
          <dt>name</dt><dd>{esc(obj or "—")}</dd>
        </dl>
      </div>
      <div class="panel">
        <h2>UserInfo</h2>
        <p class="lede">Principal as Cedar sees it. Groups exist only if you passed an entities file.</p>
        <dl class="kv">
          <dt>username</dt><dd>{esc(p_id or p_label)}</dd>
          <dt>type</dt><dd>{esc(p_type or "—")}</dd>
          <dt>uid</dt><dd>{esc(p.get("euid") or "—")}</dd>
        </dl>
      </div>
    </section>

    {verb_cells}

    <section class="panel">
      <h2>Determining policies</h2>
      <p class="lede">From <code>cedar authorize -v</code>. Policy ids are CR names unless the source already had <code>@id</code>.</p>
      {''.join(det_blocks)}
    </section>

    <section class="panel">
      <h2>Policy CRs in this request</h2>
      <p class="lede">All <code>spec.content</code> entries passed preflight and were concatenated. Any unavailable policy makes the result indeterminate.</p>
      <ul class="crs">{cr_list}</ul>
    </section>

    {dag}

    <section class="panel">
      <h2>cedar authorize</h2>
      {log_block}
    </section>

    <footer>
      Not Kubernetes RBAC and not <code>kubectl auth can-i</code>.
      Cluster <code>Policy</code> objects (<code>cedar.k8s.aws</code>) evaluated with <code>cedar authorize</code>.
      Forbid wins. Default deny. Request body / admission is not in this check.
    </footer>
  </div>
</body>
</html>
"""


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Render a Cedar can-i HTML slide")
    ap.add_argument("--out", required=True)
    ap.add_argument("--decision", required=True)
    ap.add_argument("--principal-label", default="")
    ap.add_argument("--principal-euid", default="")
    ap.add_argument("--action-label", default="")
    ap.add_argument("--action-euid", default="")
    ap.add_argument("--resource-label", default="")
    ap.add_argument("--resource-euid", default="")
    ap.add_argument("--namespace", default="")
    ap.add_argument("--apigroup", default="")
    ap.add_argument("--object-name", default="")
    ap.add_argument("--mode", default="cedar")
    ap.add_argument("--context", default="")
    ap.add_argument("--included", type=int, default=0)
    ap.add_argument("--skipped", type=int, default=0)
    ap.add_argument("--included-names", default="")
    ap.add_argument("--policies-file", default="")
    ap.add_argument("--entities-file", default="")
    ap.add_argument("--authorize-log-file", default="")
    ap.add_argument("--matrix-file", default="")
    args = ap.parse_args(argv)

    log = read_text(args.authorize_log_file)
    determining = parse_determining(log)
    names = [n for n in args.included_names.split(",") if n]
    meta = {
        "decision": args.decision,
        "principal": {"label": args.principal_label, "euid": args.principal_euid},
        "action": {"label": args.action_label, "euid": args.action_euid},
        "resource": {"label": args.resource_label, "euid": args.resource_euid},
        "namespace": args.namespace,
        "apiGroup": args.apigroup,
        "objectName": args.object_name,
        "mode": args.mode,
        "context": args.context,
        "included": args.included,
        "skipped": args.skipped,
        "includedNames": names,
        "determining": determining,
        "policies": read_text(args.policies_file),
        "entities": load_json(args.entities_file, []),
        "authorizeLog": log,
        "matrix": load_json(args.matrix_file, []),
    }
    write_atomic(args.out, render(meta))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
