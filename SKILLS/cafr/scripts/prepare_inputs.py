#!/usr/bin/env python3
"""Prepare CAFR source inputs for English cleanup and bilingual translation."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from shutil import which
from typing import Any

TEXT_EXTENSIONS = {".txt", ".md"}
TEXTUTIL_EXTENSIONS = {".doc", ".docx", ".rtf", ".odt", ".html", ".htm"}
PDF_EXTENSIONS = {".pdf"}
SUPPORTED_EXTENSIONS = TEXT_EXTENSIONS | TEXTUTIL_EXTENSIONS | PDF_EXTENSIONS


@dataclass(frozen=True)
class ExtractionResult:
    """Represent one extracted work item."""

    extractor: str
    status: str
    text: str
    page_count: int | None
    notes: list[str]


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments."""

    parser = argparse.ArgumentParser(
        description=(
            "Prepare a file or top-level folder of files for CAFR cleanup and "
            "bilingual Quebec French translation."
        )
    )
    parser.add_argument("input_path", help="Source file or folder to inspect")
    parser.add_argument(
        "--manifest-out",
        help="Optional output path for the generated JSON manifest",
    )
    parser.add_argument(
        "--work-dir",
        help=(
            "Optional working directory for extracted raw text files. "
            "Defaults to a new temporary directory."
        ),
    )
    return parser.parse_args()


def ensure_command(name: str) -> None:
    """Exit with a clear message when a required command is unavailable."""

    if which(name) is None:
        raise SystemExit(f"Required command not found: {name}")


def run_command(command: list[str]) -> str:
    """Run a command and return stdout as UTF-8 text."""

    completed = subprocess.run(
        command,
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout


def sanitize_slug(value: str) -> str:
    """Normalize a filename fragment for temporary outputs."""

    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-")
    return slug or "item"


def parse_page_count(pdfinfo_output: str) -> int | None:
    """Extract the PDF page count from pdfinfo output."""

    match = re.search(r"^Pages:\s+(\d+)\s*$", pdfinfo_output, re.MULTILINE)
    if not match:
        return None
    return int(match.group(1))


def looks_like_ocr_required(text: str) -> bool:
    """Detect an image-only or near-empty PDF extraction."""

    stripped = re.sub(r"\s+", "", text)
    if len(stripped) < 20:
        return True

    alpha_count = sum(1 for character in stripped if character.isalpha())
    return alpha_count < 10


def extract_pdf(source_path: Path) -> ExtractionResult:
    """Extract PDF text with layout preserved and record page count."""

    ensure_command("pdfinfo")
    ensure_command("pdftotext")

    pdfinfo_output = run_command(["pdfinfo", str(source_path)])
    extracted_text = run_command(
        ["pdftotext", "-layout", "-enc", "UTF-8", str(source_path), "-"]
    )

    notes: list[str] = []
    status = "ready"
    if looks_like_ocr_required(extracted_text):
        status = "ocr_required"
        notes.append(
            "Extraction looks empty or image-only; OCR is required before CAFR can continue."
        )

    return ExtractionResult(
        extractor="pdftotext-layout",
        status=status,
        text=extracted_text,
        page_count=parse_page_count(pdfinfo_output),
        notes=notes,
    )


def extract_textutil(source_path: Path) -> ExtractionResult:
    """Extract text from rich document formats with textutil."""

    ensure_command("textutil")
    extracted_text = run_command(
        ["textutil", "-convert", "txt", "-stdout", "-encoding", "UTF-8", str(source_path)]
    )
    notes: list[str] = []
    if not extracted_text.strip():
        notes.append("textutil returned empty text; review the source manually.")
    return ExtractionResult(
        extractor="textutil",
        status="ready",
        text=extracted_text,
        page_count=None,
        notes=notes,
    )


def extract_direct_text(source_path: Path) -> ExtractionResult:
    """Read text-like files directly."""

    extracted_text = source_path.read_text(encoding="utf-8-sig", errors="replace")
    notes: list[str] = []
    if not extracted_text.strip():
        notes.append("Source file is empty after decoding.")
    return ExtractionResult(
        extractor="direct-read",
        status="ready",
        text=extracted_text,
        page_count=None,
        notes=notes,
    )


def extract_source(source_path: Path) -> ExtractionResult:
    """Dispatch extraction based on the source extension."""

    suffix = source_path.suffix.lower()
    if suffix in PDF_EXTENSIONS:
        return extract_pdf(source_path)
    if suffix in TEXTUTIL_EXTENSIONS:
        return extract_textutil(source_path)
    if suffix in TEXT_EXTENSIONS:
        return extract_direct_text(source_path)
    raise ValueError(f"Unsupported input extension: {suffix}")


def source_kind_for_path(source_path: Path) -> str:
    """Return the high-level source kind for manifest consumers."""

    suffix = source_path.suffix.lower()
    if suffix in PDF_EXTENSIONS:
        return "pdf"
    if suffix == ".md":
        return "markdown"
    if suffix == ".txt":
        return "plain_text"
    if suffix in {".html", ".htm"}:
        return "html"
    return "rich_document"


def english_output_path_for(source_path: Path) -> Path:
    """Return the adjacent English Markdown output path."""

    if source_path.suffix.lower() == ".md":
        return source_path
    return source_path.with_suffix(".md")


def french_output_path_for(source_path: Path) -> Path:
    """Return the adjacent bilingual French Markdown output path."""

    return source_path.with_name(f"{source_path.stem}_fr.md")


def build_candidate_list(input_path: Path) -> tuple[list[Path], list[dict[str, str]]]:
    """Collect supported source files and skipped entries."""

    if input_path.is_file():
        suffix = input_path.suffix.lower()
        if suffix not in SUPPORTED_EXTENSIONS:
            raise SystemExit(f"Unsupported input type: {input_path.suffix or '<none>'}")
        return [input_path], []

    if not input_path.is_dir():
        raise SystemExit(f"Input path does not exist: {input_path}")

    skipped: list[dict[str, str]] = []
    entries = sorted(input_path.iterdir(), key=lambda entry: entry.name.lower())

    sibling_source_stems = {
        entry.stem
        for entry in entries
        if entry.is_file()
        and entry.suffix.lower() in (PDF_EXTENSIONS | TEXTUTIL_EXTENSIONS | {".txt"})
    }

    candidates: list[Path] = []
    for entry in entries:
        resolved_path = str(entry.resolve())
        if entry.is_dir():
            skipped.append(
                {
                    "path": resolved_path,
                    "reason": "nested_directory_not_traversed",
                }
            )
            continue

        suffix = entry.suffix.lower()
        if suffix not in SUPPORTED_EXTENSIONS:
            skipped.append(
                {
                    "path": resolved_path,
                    "reason": "unsupported_extension",
                }
            )
            continue

        if entry.name.endswith("_fr.md"):
            skipped.append(
                {
                    "path": resolved_path,
                    "reason": "generated_french_output",
                }
            )
            continue

        if suffix == ".md" and entry.stem in sibling_source_stems:
            skipped.append(
                {
                    "path": resolved_path,
                    "reason": "generated_markdown_output",
                }
            )
            continue

        candidates.append(entry)

    return candidates, skipped


def build_manifest_item(
    index: int,
    source_path: Path,
    work_dir: Path,
) -> dict[str, Any]:
    """Extract one source item and return its manifest entry."""

    extraction = extract_source(source_path)
    raw_text_name = f"{index:03d}-{sanitize_slug(source_path.stem)}-raw.txt"
    raw_text_path = work_dir / raw_text_name
    raw_text_path.write_text(extraction.text, encoding="utf-8")

    english_output_path = english_output_path_for(source_path)
    french_output_path = french_output_path_for(source_path)
    english_output_collides_with_source = english_output_path.resolve() == source_path.resolve()
    english_output_exists = english_output_path.exists()
    french_output_exists = french_output_path.exists()

    return {
        "source_path": str(source_path.resolve()),
        "source_name": source_path.name,
        "source_extension": source_path.suffix.lower(),
        "source_kind": source_kind_for_path(source_path),
        "status": extraction.status,
        "extractor": extraction.extractor,
        "page_count": extraction.page_count,
        "raw_text_path": str(raw_text_path.resolve()),
        "english_output_path": str(english_output_path.resolve()),
        "french_output_path": str(french_output_path.resolve()),
        "english_output_exists": english_output_exists,
        "french_output_exists": french_output_exists,
        "english_output_collides_with_source": english_output_collides_with_source,
        "requires_explicit_overwrite": (
            english_output_exists
            or french_output_exists
            or english_output_collides_with_source
        ),
        "notes": extraction.notes,
    }


def prepare_manifest(
    input_path: Path,
    work_dir: Path,
) -> dict[str, Any]:
    """Prepare all manifest data for the provided input path."""

    candidates, skipped = build_candidate_list(input_path)
    items = [
        build_manifest_item(index=index, source_path=source_path, work_dir=work_dir)
        for index, source_path in enumerate(candidates, start=1)
    ]

    summary = {
        "total_items": len(items),
        "ready_items": sum(1 for item in items if item["status"] == "ready"),
        "ocr_required_items": sum(
            1 for item in items if item["status"] == "ocr_required"
        ),
        "skipped_entries": len(skipped),
    }

    return {
        "manifest_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "input_path": str(input_path.resolve()),
        "input_kind": "file" if input_path.is_file() else "directory",
        "work_dir": str(work_dir.resolve()),
        "items": items,
        "skipped": skipped,
        "summary": summary,
    }


def write_manifest(manifest: dict[str, Any], manifest_path: Path) -> None:
    """Write the JSON manifest to disk."""

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def print_summary(manifest: dict[str, Any], manifest_path: Path) -> None:
    """Emit a concise human-readable summary."""

    summary = manifest["summary"]
    print(f"Manifest: {manifest_path}")
    print(f"Work dir: {manifest['work_dir']}")
    print(f"Items: {summary['total_items']}")
    print(f"Ready: {summary['ready_items']}")
    print(f"OCR required: {summary['ocr_required_items']}")
    print(f"Skipped: {summary['skipped_entries']}")


def main() -> int:
    """Run the CAFR prep flow."""

    args = parse_args()
    input_path = Path(args.input_path).expanduser().resolve()

    if args.work_dir:
        work_dir = Path(args.work_dir).expanduser().resolve()
        work_dir.mkdir(parents=True, exist_ok=True)
    else:
        work_dir = Path(tempfile.mkdtemp(prefix="cafr-prepare-"))

    manifest = prepare_manifest(input_path=input_path, work_dir=work_dir)

    if args.manifest_out:
        manifest_path = Path(args.manifest_out).expanduser().resolve()
    else:
        manifest_path = work_dir / "manifest.json"

    write_manifest(manifest, manifest_path)
    print_summary(manifest, manifest_path)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        if error.stderr:
            sys.stderr.write(error.stderr)
        raise SystemExit(error.returncode)
