# Quebec French and QA

## Quebec French Rules

Use clear, neutral Canadian or Quebec French.

Prefer:

- natural institutional French
- readable, direct phrasing
- preserved operational clarity for steps, contact instructions, and support
  language

Preserve marketing tone when the source is marketing copy, but do not force a
literal English-to-French mapping.

## Required Typography

Use real UTF-8 accented characters:

- `é`, `è`, `ê`, `ë`
- `à`, `â`
- `î`, `ï`
- `ô`
- `ù`, `û`, `ü`
- `ç`

Use proper French quotation marks:

- `« ... »`

Use standard apostrophes and contractions:

- `d'aide`
- `l'équipe`
- `qu'il`

Do not force English title casing into French.

## Leave Unchanged When Appropriate

Keep these unchanged when they are source identifiers rather than French prose:

- URLs
- phone numbers
- email addresses
- filenames
- brand names
- acronyms
- product names

Examples:

- keep `MembersHealth`
- keep `https://membershealth.ca/book`
- keep `1-800-484-0152`
- keep acronyms such as `EFAP`, `PAEF`, `PTSD`, `TSPT` when context requires
  them

## Bilingual Layout Pattern

Always keep English first, then French.

```md
Members can access support 24/7.
**FR:** Les membres peuvent accéder à du soutien 24 h sur 24, 7 jours sur 7.
```

```md
- Call 1-800-484-0152
  **FR:** Appelez au 1-800-484-0152
```

```md
1. Call and request support.
   **FR:** Appelez et demandez du soutien.
```

## Final QA Checklist

Before calling a document done, verify:

- English `.md` exists
- bilingual `_fr.md` exists
- no raw form-feed characters remain in final outputs
- French file contains `**FR:**` lines throughout
- French text uses UTF-8 accents and special characters
- quoted French text uses guillemets `« »`
- English blocks remain in place
- French blocks appear immediately under the matching English blocks
- URLs, phone numbers, emails, and acronyms remain intact
- layout-sensitive pages were visually checked when extraction order was
  ambiguous

For batches, also verify:

- every source file has both outputs
- naming is consistent across the set
- no source file was skipped unintentionally
