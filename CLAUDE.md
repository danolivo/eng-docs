# Instructions for Claude sessions

This repository stores engineering documents: specifications, technical descriptions,
verification and validation plans, methods.

## Every time you add, rename, move or delete a document

1. Put the document into the directory that matches its kind (`methods/`, and so on;
   create a new directory if none fits).
2. Update the **Documents** section of `README.md` in the same commit:
   - one table row per document, under the heading of its directory
     (add a new `### <Kind> (`<dir>/`)` heading with the same table header if needed);
   - the title is a direct link to the file on GitHub:
     `https://github.com/danolivo/eng-docs/blob/main/<path>`;
   - `Language` column: `EN`, `RU`, etc.;
   - a one- or two-sentence description in English, even when the document itself
     is in another language: what the document is for and what it covers;
   - on rename, move or delete, fix or remove the row; never leave a dead link.
3. Check that every file under the document directories has a README row, and every
   README row points to an existing file.

## Conventions

- File names: lowercase, words separated by hyphens, language suffix before the
  extension (`-ru.md`, `-en.md`).
- The README is written in English.
- Do not commit `.DS_Store` or other OS/editor artefacts.
