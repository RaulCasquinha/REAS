# docs/report/

The written report deliverable for this coursework.

- `template.tex` — the actual report source. Structure: Abstract, Introduction, State of the Art,
  Methodology, Results (one `\subsection` per chapter — Kubernetes, Service Mesh, and eventually
  WordPress), Discussion, Conclusion.
- `template.pdf` — compiled output (`latexmk -pdf template.tex`).
- `bibliography/` — `references.bib` for citations (currently empty; `\addbibresource` is
  commented out in `template.tex` until there's something to cite).
- `ref.tex` — **not part of this report.** It's a leftover Software Requirements Specification for
  an unrelated "Plan-Scales" project from a different course. Not included/referenced by
  `template.tex`; safe to ignore or remove.

## Building

```bash
latexmk -pdf template.tex
```

## Report status

| Chapter | Report section | Status |
|---|---|---|
| WordPress / Load Balancing | — | Not written yet (chapter itself not benchmarked) |
| Kubernetes | `Results → Kubernetes` | Complete, backed by real log data |
| Service Mesh | `Results → Service Mesh` | Marked pending — script written, not yet executed |
