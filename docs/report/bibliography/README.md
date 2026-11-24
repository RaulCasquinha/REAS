# docs/report/bibliography/

`references.bib` — BibTeX/biblatex source for the report's citations. Currently empty;
`template.tex` has `\addbibresource{bib/references.bib}` commented out until there's something to
cite. To enable: add entries here, uncomment that line (and `\printbibliography[...]` at the end of
`template.tex`), then rebuild with `latexmk -pdf -bibtex template.tex` (biber needs an extra pass).
