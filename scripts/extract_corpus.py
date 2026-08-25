#!/usr/bin/env python3
"""Extract text from corpus PDFs and upsert corpus/manifest.json.

Does not guess supersession from titles. `series` must come from a sidecar
`.meta.json` or `--series`. Within a (framework, series) group, publication
dates build the supersedes / supersededBy chain; the newest date is active.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

FRAMEWORKS = {"FATF", "OFAC", "MICA", "TFR", "FINCEN", "TREASURY", "WOLFSBERG"}
FILENAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2})_(.+)\.pdf$", re.IGNORECASE)
MANIFEST_KEYS = (
    "id",
    "framework",
    "series",
    "title",
    "sourceUrl",
    "publicationDate",
    "retrievedAt",
    "pdfPath",
    "txtPath",
    "sha256",
    "txtSha256",
    "supersedes",
    "supersededBy",
    "status",
)


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def posix_rel(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def load_manifest(path: Path) -> list[dict]:
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        raise SystemExit("manifest.json must be a JSON array")
    return data


def dump_manifest(path: Path, entries: list[dict]) -> None:
    ordered = [{k: row[k] for k in MANIFEST_KEYS} for row in entries]
    ordered.sort(key=lambda row: (row["framework"], row["series"], row["publicationDate"], row["id"]))
    path.write_text(json.dumps(ordered, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def load_sidecar(pdf: Path) -> dict:
    meta_path = pdf.with_suffix(".meta.json")
    if not meta_path.exists():
        return {}
    data = json.loads(meta_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit(f"{meta_path}: sidecar must be a JSON object")
    return data


def parse_pdf_name(pdf: Path) -> tuple[str, str]:
    match = FILENAME_RE.match(pdf.name)
    if not match:
        raise SystemExit(
            f"{pdf}: name must be YYYY-MM-DD_slug.pdf (got {pdf.name!r})"
        )
    return match.group(1), match.group(2)


def framework_of(corpus_root: Path, pdf: Path) -> str:
    rel = pdf.resolve().relative_to(corpus_root.resolve())
    folder = rel.parts[0].upper()
    if folder not in FRAMEWORKS:
        raise SystemExit(f"{pdf}: parent folder must be one of {sorted(FRAMEWORKS)}")
    return folder


def extract_text(pdf: Path) -> str:
    try:
        import pdfplumber
    except ImportError as exc:
        raise SystemExit(
            "pdfplumber is required. Install with: pip install -r scripts/requirements-corpus.txt"
        ) from exc

    pages: list[str] = []
    with pdfplumber.open(pdf) as doc:
        for page in doc.pages:
            pages.append((page.extract_text() or "").rstrip())
    text = "\n\n".join(pages).strip() + "\n"
    return text


def slug_id(framework: str, publication_date: str, slug: str) -> str:
    return f"{framework.lower()}-{publication_date}-{slug}".lower()


def title_from_slug(slug: str) -> str:
    return slug.replace("-", " ").replace("_", " ").strip().title()


def relink_series(entries: list[dict]) -> None:
    groups: dict[tuple[str, str], list[dict]] = {}
    for row in entries:
        groups.setdefault((row["framework"], row["series"]), []).append(row)

    for group in groups.values():
        group.sort(key=lambda row: (row["publicationDate"], row["id"]))
        dates = [row["publicationDate"] for row in group]
        if len(dates) != len(set(dates)):
            ids = ", ".join(row["id"] for row in group)
            raise SystemExit(
                f"duplicate publicationDate in series {group[0]['framework']}/{group[0]['series']}: {ids}"
            )
        for i, row in enumerate(group):
            row["supersedes"] = group[i - 1]["id"] if i else None
            row["supersededBy"] = group[i + 1]["id"] if i + 1 < len(group) else None
            row["status"] = "active" if i == len(group) - 1 else "superseded"


def upsert_entry(
    entries: list[dict],
    *,
    new_row: dict,
) -> None:
    by_id = {row["id"]: i for i, row in enumerate(entries)}
    if new_row["id"] in by_id:
        prev = entries[by_id[new_row["id"]]]
        # Keep retrievedAt from the first add; preserve series/title unless replaced.
        new_row["retrievedAt"] = prev.get("retrievedAt") or new_row["retrievedAt"]
        entries[by_id[new_row["id"]]] = new_row
        return
    entries.append(new_row)


def process_pdf(
    corpus_root: Path,
    pdf: Path,
    entries: list[dict],
    args: argparse.Namespace,
) -> None:
    framework = framework_of(corpus_root, pdf)
    pub_from_name, slug = parse_pdf_name(pdf)
    sidecar = load_sidecar(pdf)
    series = args.series or sidecar.get("series")
    existing = next(
        (
            row
            for row in entries
            if row.get("pdfPath") == posix_rel(corpus_root.parent, pdf)
            or row.get("id") == (args.id or sidecar.get("id"))
        ),
        None,
    )
    if not series:
        series = existing.get("series") if existing else None
    if not series:
        raise SystemExit(
            f"{pdf}: missing series. Add {pdf.with_suffix('.meta.json')} or pass --series"
        )

    publication_date = (
        args.publication_date
        or sidecar.get("publicationDate")
        or (existing.get("publicationDate") if existing else None)
        or pub_from_name
    )
    doc_id = (
        args.id
        or sidecar.get("id")
        or (existing.get("id") if existing else None)
        or slug_id(framework, publication_date, slug)
    )
    title = (
        args.title
        or sidecar.get("title")
        or (existing.get("title") if existing else None)
        or title_from_slug(slug)
    )
    source_url = (
        args.source_url
        if args.source_url is not None
        else sidecar.get("sourceUrl", existing.get("sourceUrl") if existing else None)
    )
    if source_url == "":
        source_url = None

    txt_path = pdf.with_suffix(".txt")
    pdf_hash = sha256_file(pdf)
    should_extract = True
    if txt_path.exists() and existing and existing.get("sha256") == pdf_hash:
        should_extract = False
    elif txt_path.exists() and existing is None:
        # TXT already on disk (manual) and no manifest row yet: keep it.
        should_extract = False

    if should_extract:
        txt_path.write_text(extract_text(pdf), encoding="utf-8")
        print(f"extracted {posix_rel(corpus_root.parent, pdf)}")
    else:
        print(f"kept txt {posix_rel(corpus_root.parent, txt_path)}")

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    retrieved_at = existing.get("retrievedAt") if existing else now

    upsert_entry(
        entries,
        new_row={
            "id": doc_id,
            "framework": framework,
            "series": series,
            "title": title,
            "sourceUrl": source_url,
            "publicationDate": publication_date,
            "retrievedAt": retrieved_at,
            "pdfPath": posix_rel(corpus_root.parent, pdf),
            "txtPath": posix_rel(corpus_root.parent, txt_path),
            "sha256": pdf_hash,
            "txtSha256": sha256_file(txt_path),
            "supersedes": None,
            "supersededBy": None,
            "status": "active",
        },
    )


def iter_pdfs(corpus_root: Path, paths: list[str]) -> list[Path]:
    if paths:
        pdfs = []
        for raw in paths:
            path = Path(raw).resolve()
            if not path.exists():
                raise SystemExit(f"not found: {raw}")
            if path.suffix.lower() != ".pdf":
                raise SystemExit(f"not a PDF: {raw}")
            pdfs.append(path)
        return pdfs
    return sorted(p for p in corpus_root.glob("*/*.pdf") if p.is_file())


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract corpus PDFs and update manifest.json")
    parser.add_argument("--corpus", type=Path, default=None, help="corpus directory (default: <repo>/corpus)")
    parser.add_argument("--series", default=None, help="series key applied to PDFs that lack a sidecar")
    parser.add_argument("--title", default=None)
    parser.add_argument("--source-url", dest="source_url", default=None)
    parser.add_argument("--publication-date", dest="publication_date", default=None)
    parser.add_argument("--id", default=None)
    parser.add_argument("paths", nargs="*", help="specific PDFs; default is corpus/*/*.pdf")
    args = parser.parse_args()

    root = repo_root()
    corpus_root = (args.corpus or (root / "corpus")).resolve()
    manifest_path = corpus_root / "manifest.json"
    entries = load_manifest(manifest_path)

    pdfs = iter_pdfs(corpus_root, args.paths)
    if not pdfs:
        dump_manifest(manifest_path, entries)
        print("no PDFs found; manifest unchanged")
        return 0

    for pdf in pdfs:
        process_pdf(corpus_root, pdf, entries, args)

    relink_series(entries)
    dump_manifest(manifest_path, entries)
    print(f"wrote {posix_rel(root, manifest_path)} ({len(entries)} documents)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
