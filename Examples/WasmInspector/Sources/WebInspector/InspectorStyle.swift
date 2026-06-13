extension InspectorView {
    /// The inspector's dark theme. Injected once into <head>. Mirrors the native inspector's palette
    /// (monospace JSON, kind badges, state pills) without trying to be a pixel clone.
    static let css = """
    :root {
      --insp-bg: #15151a; --insp-panel: #1c1c23; --insp-line: #2a2a34;
      --insp-fg: #d7d7e0; --insp-dim: #8a8a99; --insp-accent: #7c5cff;
      --insp-key: #c0a7ff; --insp-string: #7fd1a8; --insp-number: #f0b86e;
      --insp-bool: #6ea8ff; --insp-null: #8a8a99; --insp-type: #8a8a99;
    }
    .insp-root { display:flex; flex-direction:column; height:100%; background:var(--insp-bg);
      color:var(--insp-fg); font:13px/1.4 -apple-system, system-ui, sans-serif; }
    .insp-header { display:flex; align-items:center; gap:.5rem; padding:.6rem .9rem;
      border-bottom:1px solid var(--insp-line); }
    .insp-logo { color:var(--insp-accent); font-size:1rem; }
    .insp-title { font-weight:600; }
    .insp-sub { color:var(--insp-dim); font-size:.78rem; margin-left:.25rem; }
    .insp-body { display:flex; flex:1; min-height:0; }
    .insp-sidebar { width:240px; min-width:200px; border-right:1px solid var(--insp-line);
      overflow:auto; padding:.5rem 0; }
    .insp-section-title { color:var(--insp-dim); font-size:.7rem; letter-spacing:.08em;
      padding:.4rem .9rem; }
    .insp-actor { display:flex; align-items:center; gap:.45rem; padding:.35rem .9rem;
      cursor:pointer; border-left:2px solid transparent; }
    .insp-actor:hover { background:#ffffff08; }
    .insp-actor-sel { background:#7c5cff1f; border-left-color:var(--insp-accent); }
    .insp-actor-name { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .insp-dot { width:8px; height:8px; border-radius:50%; flex:0 0 auto; background:var(--insp-dim); }
    .insp-dot-active { background:#5ad17f; } .insp-dot-done { background:#6ea8ff; }
    .insp-dot-error { background:#ff6e6e; } .insp-dot-stopped { background:#8a8a99; }
    .insp-pill { font-size:.72rem; color:var(--insp-accent); background:#7c5cff1a;
      padding:.05rem .4rem; border-radius:6px; max-width:90px; overflow:hidden;
      text-overflow:ellipsis; white-space:nowrap; }
    .insp-main { flex:1; display:flex; flex-direction:column; min-width:0; }
    .insp-tabs { display:flex; gap:.25rem; padding:.4rem .6rem; border-bottom:1px solid var(--insp-line); }
    .insp-tab { background:transparent; color:var(--insp-dim); border:0; padding:.3rem .7rem;
      border-radius:7px; cursor:pointer; font-size:.82rem; }
    .insp-tab:hover { color:var(--insp-fg); }
    .insp-tab-sel { background:var(--insp-accent); color:#fff; }
    .insp-content { flex:1; min-height:0; position:relative; }
    .insp-panel { position:absolute; inset:0; overflow:auto; padding:.8rem 1rem; }
    .insp-empty { color:var(--insp-dim); padding:1rem; }
    .insp-state-head { display:flex; align-items:center; gap:.5rem; margin-bottom:.4rem; }
    .insp-state-name { font-weight:600; }
    .insp-tag { font-size:.7rem; padding:.05rem .4rem; border-radius:5px; background:#ffffff14; color:var(--insp-dim); }
    .insp-tag-active { color:#5ad17f; } .insp-tag-error { color:#ff6e6e; }
    .insp-value { font:12px/1.4 ui-monospace, Menlo, monospace; background:var(--insp-panel);
      border:1px solid var(--insp-line); border-radius:8px; padding:.5rem .7rem; margin:.2rem 0 .6rem;
      color:var(--insp-accent); }
    .insp-event-buttons { display:flex; flex-wrap:wrap; gap:.35rem; margin:0 0 .6rem; }
    .insp-send { background:#7c5cff22; color:var(--insp-key); border:1px solid #7c5cff44;
      border-radius:6px; padding:.25rem .6rem; cursor:pointer; font-size:.78rem; }
    .insp-send:hover { background:#7c5cff3a; }
    .json-tree, .json-children { font:12px/1.5 ui-monospace, Menlo, monospace; }
    .json-children { padding-left:1.1rem; border-left:1px solid var(--insp-line); margin-left:.3rem; }
    .json-summary { cursor:pointer; list-style:none; padding:.05rem 0; }
    .json-summary::-webkit-details-marker { display:none; }
    .json-summary::before { content:"▸"; color:var(--insp-dim); display:inline-block;
      width:1em; transition:transform .1s; }
    details[open] > .json-summary::before { transform:rotate(90deg); }
    .json-leaf { padding:.05rem 0 .05rem 1em; }
    .json-key { color:var(--insp-key); } .json-type { color:var(--insp-type); }
    .json-string { color:var(--insp-string); } .json-number { color:var(--insp-number); }
    .json-bool { color:var(--insp-bool); } .json-null { color:var(--insp-null); }
    .json-object, .json-array { color:var(--insp-type); }
    .insp-feed-row { border-bottom:1px solid var(--insp-line); }
    .insp-feed-summary { cursor:pointer; display:flex; align-items:center; gap:.5rem;
      padding:.35rem .1rem; list-style:none; }
    .insp-feed-summary::-webkit-details-marker { display:none; }
    .insp-kind { font-size:.65rem; letter-spacing:.05em; padding:.05rem .35rem; border-radius:5px;
      background:#ffffff14; color:var(--insp-dim); }
    .insp-kind-event { color:#6ea8ff; background:#6ea8ff1a; }
    .insp-kind-snapshot { color:#5ad17f; background:#5ad17f1a; }
    .insp-kind-actor { color:var(--insp-accent); background:#7c5cff1a; }
    .insp-feed-label { flex:1; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
    .insp-feed-time { color:var(--insp-dim); font-size:.72rem; font-variant-numeric:tabular-nums; }
    .insp-seq-row { display:flex; align-items:center; gap:.5rem; padding:.2rem 0;
      font:12px/1.4 ui-monospace, Menlo, monospace; border-bottom:1px solid #ffffff08; }
    .insp-seq-actor { color:var(--insp-key); } .insp-seq-arrow { color:var(--insp-dim); }
    .insp-seq-event { color:var(--insp-fg); }
    .insp-graph { width:100%; max-width:760px; border-radius:10px; background:#0f0f12;
      touch-action:none; cursor:grab; display:block; margin:0 auto; }
    """
}
