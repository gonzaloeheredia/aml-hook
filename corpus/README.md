# Regulatory corpus

Versioned FATF (Financial Action Task Force), FinCEN (Financial Crimes Enforcement Network), U.S. Treasury, Wolfsberg, OFAC (Office of Foreign Assets Control), MiCA (Markets in Crypto-Assets), and TFR (Transfer of Funds Regulation) documents that `search_regulations` may cite. The COA (Compliance Officer Agent) answers normative questions from this tree only. It does not answer those questions from model training memory.

OFAC here is **guidance text** (for example VC Industry Guidance). The live sanctions list used at swap time is `SanctionRegistry`. A PDF in git is not that list. FinCEN / Treasury rows are BSA (Bank Secrecy Act) and illicit-finance assessments. They are not SDN (Specially Designated Nationals) dumps.

## Layout

```
corpus/
  manifest.json
  fatf/   fincen/   treasury/   wolfsberg/   ofac/   mica/   tfr/
    YYYY-MM-DD_slug.pdf
    YYYY-MM-DD_slug.txt
    YYYY-MM-DD_slug.meta.json   # optional sidecar
```

Each framework folder holds immutable versions. A newer list **adds** files. It never overwrites or deletes an older PDF or `.txt`.

## `series`

Supersession is keyed by `(framework, series)`. Similar titles do not key supersession.

Examples: `fatf-recommendations`, `vasp-guidance`, `defi-targeted-report`,
`virtual-currency-msb`, `cvc-business-models`, `cvc-kiosks`,
`defi-illicit-finance-risk-assessment`, `digital-assets-faqs`.

At most one document per `(framework, series)` may be `active`. Older rows stay
in git with `status: superseded` and a `supersedes` / `supersededBy` chain.

`getActiveVersionAt(framework, series, date)` returns the version whose
`publicationDate` made it the in-force text on that date, including documents
that are superseded today. That is how a dispute recalculation reconstructs an
Opinion.

## Add a document

1. Place the official PDF under the matching framework folder, named
   `YYYY-MM-DD_slug.pdf` (publication date, English slug).
2. Add a sidecar `YYYY-MM-DD_slug.meta.json` (or pass CLI (command-line interface) flags):

   ```json
   {
     "series": "high-risk-jurisdictions",
     "title": "FATF High-Risk Jurisdictions subject to a Call for Action",
     "sourceUrl": "https://www.fatf-gafi.org/..."
   }
   ```

3. Extract and update the manifest (repo root):

   ```bash
   pip install -r scripts/requirements-corpus.txt
   python scripts/extract_corpus.py
   ```

   Windows: `py -3 scripts/extract_corpus.py`

4. Read the generated `.txt`. Fix OCR (optical character recognition) or layout by hand if needed. Re-running
   extract will **not** overwrite that `.txt` while the PDF hash is unchanged.
5. Commit the PDF, `.txt`, sidecar (if any), and `manifest.json` **in one
   commit**.

Then restart the API (application programming interface) or `POST /reset` so live Claude Opinions (and score
justifications) pick up the new cites.

## Point-in-time reconstruction

Each Opinion stores `technicalOpinion.normativeCitations` (`id`,
`publicationDate`, `retrievedAt`, `sha256`) at calculation time. Git history of
this folder is the document store. The citation pack on the Opinion is what was
actually used.

To evaluate a past fact date, call `getActiveVersionAt` / `searchRegulations`
with `asOf` set to that date.

## Validate

```bash
npm run validate:corpus
```

GitHub Actions runs the same check on changes under `corpus/` or the extract /
validate scripts.

Do not use Git LFS (Large File Storage) for this tree.
