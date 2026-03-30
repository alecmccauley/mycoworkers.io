---
name: cafr
description: Prepare PDFs and document files into cleaned English Markdown and bilingual Quebec French layout-reference Markdown. Use when Codex is asked to process a PDF, DOCX, DOC, RTF, ODT, HTML, TXT, Markdown file, or a top-level folder of such files into adjacent `basename.md` and `basename_fr.md` outputs with English preserved in place and French blocks prefixed with `**FR:**`. Invoke explicitly as `$cafr`.
---

# CAFR

## Overview

Use this skill to turn source documents into:

- cleaned English Markdown
- bilingual Quebec French layout-reference Markdown

Keep the English scaffold in place. Place each French translation immediately
under the matching English block and prefix it with `**FR:**`.

## Quick Start

Invoke explicitly with `$cafr`.

Run the prep script first:

```bash
python3 scripts/prepare_inputs.py <file-or-folder>
```

Use `--manifest-out` when you want a stable manifest path:

```bash
python3 scripts/prepare_inputs.py <file-or-folder> --manifest-out /tmp/cafr-manifest.json
```

Then read the manifest and work item by work item.

- If `status` is `ocr_required`, stop and tell the user the file needs OCR
  before CAFR cleanup or translation.
- If `english_output_exists`, `french_output_exists`, or
  `english_output_collides_with_source` is `true`, do not overwrite unless the
  user explicitly asks.
- If the input is a folder, process only the files listed in the manifest.
  Folder traversal is top-level only.

## Workflow

1. Read `references/workflow.md`.
2. Run `scripts/prepare_inputs.py`.
3. Create or revise the English `.md` first.
4. Use the English file as the scaffold for `_fr.md`.
5. Read `references/quebec-french.md` before translating.
6. Perform a final QA pass against the checklist in
   `references/quebec-french.md`.

## English Output Rules

- Preserve source meaning and coverage.
- Normalize broken wraps into readable paragraphs.
- Convert obvious headings and lists into Markdown.
- Keep URLs, phone numbers, emails, filenames, brand names, and acronyms
  intact.
- Use `---` page separators when page boundaries matter.
- Do not invent missing text.
- Do not silently drop awkward content.

## French Output Rules

- Keep the English block exactly where it is.
- Put the French translation immediately underneath.
- Prefix each French block with `**FR:**`.
- Do not replace the English scaffold.
- Do not reorder the document.
- Leave identifiers unchanged when appropriate: URLs, phone numbers, emails,
  filenames, brand names, acronyms, and product names.

## Layout Checks

For PDFs with columns, callouts, cards, trifold layouts, sidebars, or uncertain
reading order, render representative pages before restructuring:

```bash
pdftoppm -png -f 1 -l 2 <file.pdf> /tmp/cafr-page
```

The prep script already runs `pdfinfo` and `pdftotext` for PDF inputs. Use page
renders only when reading order is ambiguous.

## Supported Inputs

- `.pdf`
- `.txt`
- `.md`
- `.doc`
- `.docx`
- `.rtf`
- `.odt`
- `.html`
- `.htm`

PDFs are first-class. OCR is not built in. Image-only or scanned PDFs must be
OCR'd before cleanup.

## Output Contract

For `basename.ext`, write adjacent outputs:

- `basename.md`
- `basename_fr.md`

Exception:

- For `.md` inputs, the English output path collides with the source file.
  Treat that as an explicit-overwrite case and do not mutate the source
  Markdown unless the user asks.

