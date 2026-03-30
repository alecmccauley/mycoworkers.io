# CAFR Workflow

## Purpose

Use CAFR when a source document needs to become:

1. a cleaned English Markdown file
2. a bilingual Quebec French layout-reference Markdown file

The bilingual file must keep the English content in place and put the French
translation immediately underneath each English block.

## Inputs

Supported source inputs:

- PDF
- TXT
- Markdown
- DOC
- DOCX
- RTF
- ODT
- HTML

The prep script supports a single file or a top-level folder of files. Folder
processing is not recursive.

## Prep Script Contract

Run:

```bash
python3 scripts/prepare_inputs.py <file-or-folder>
```

The script:

- detects supported files
- extracts raw text into a temporary work directory
- writes a JSON manifest
- computes adjacent output paths
- flags overwrite collisions
- marks scanned or image-only PDFs as `ocr_required`

Manifest status handling:

- `ready`: proceed with cleanup and translation
- `ocr_required`: stop and tell the user OCR must happen before CAFR can
  continue

Important manifest fields:

- `raw_text_path`
- `english_output_path`
- `french_output_path`
- `english_output_exists`
- `french_output_exists`
- `english_output_collides_with_source`
- `requires_explicit_overwrite`

If any overwrite flag is true, do not overwrite unless the user explicitly
asks.

## English Markdown Output

For each source `basename.ext`, create `basename.md`.

The English file should:

- preserve meaning and source coverage
- normalize broken line wrapping into readable paragraphs
- convert obvious headings into Markdown headings
- convert obvious bullet lists or numbered steps into Markdown lists
- use `---` page separators when page boundaries matter
- keep contact info, URLs, phone numbers, emails, and filenames
- preserve source truncation when the original source is truncated

Do not:

- invent missing source text
- silently remove meaningful content
- translate inside the English file
- over-polish the source beyond cleanup

## Bilingual French Output

For each source `basename.ext`, create `basename_fr.md`.

Mirror the English file block-for-block.

For every English block:

- keep the English heading, paragraph, or list item exactly where it is
- add the French translation immediately underneath
- prefix the French line with `**FR:**`

Patterns:

```md
## Employee Assistance Program
**FR:** Programme d'aide aux employés

Members can access support 24/7.
**FR:** Les membres peuvent accéder à du soutien 24 h sur 24, 7 jours sur 7.

- Call 1-800-484-0152
  **FR:** Appelez au 1-800-484-0152
```

```md
1. Call and request support.
   **FR:** Appelez et demandez du soutien.
```

Do not:

- replace English with French
- create a French-only version
- reorder content differently from the English structure
- leave untranslated English blocks inside the French file unless they are
  intentionally unchanged identifiers

## Layout Handling

For PDFs:

- start with `pdftotext`
- use `pdfinfo` metadata from the manifest when page count matters
- render representative pages with `pdftoppm` when the layout includes columns,
  callouts, sidebars, cards, or trifold structure

For layout-heavy documents:

- build the English `.md` first
- use the English file as the translation scaffold
- translate only the French lines in `_fr.md`

## Safe Cleanup

- join wrapped paragraphs
- rebuild headings from obvious extracted headings
- convert two-column fragments into correct reading order only after visual
  verification
- convert obvious step sequences into ordered lists
- convert obvious feature lists into bullets
- rejoin split links
- normalize stray extraction spacing

## Unsafe Cleanup

Do not, without source evidence:

- invent content
- correct factual claims
- change dates, names, phone numbers, URLs, or addresses
- silently drop awkward page content

## Batch Guidance

For batches:

- process simple top-level files in parallel when the task allows it
- isolate layout-heavy documents into their own pass
- finish with one consistency pass across the batch

Each worker should own a disjoint file set and should not edit files outside
that scope.
