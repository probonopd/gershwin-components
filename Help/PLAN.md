# Help.app Implementation Plan

Based on SPEC.md. Scope of this effort: **Phase 1 MVP** plus the man parser
(Phase 2 core). GSdoc parser lands as Phase 3 follow-up if time allows.
StepDown (github.com/gcasa/stepdown, also referenced in Build's Catalog.plist)
is available at /Developer/Library/Sources/stepdown, but exposes no AST -
its MarkdownRenderer goes straight to NSAttributedString. So `GSMarkdownParser`
is written fresh against GSHelpDocument, using StepDown's renderer only as a
dialect/reference for supported Markdown constructs (SPEC 12 isolation rule).

## Conventions

- GNUstep make, ARC (`-fobjc-arc`, `-fobjc-runtime=gnustep-2.0`).
- Red/green TDD with ObjectTesting (`Testing.h`); one test tool per concern,
  `Tests/<Area>/` mirroring `Sources/`.
- New files: BSD-2-Clause header (project is non-GPL).
- No em-dashes. No HTML/network dependencies anywhere.
- Install to SYSTEM domain only.

## Milestones

### M0 - Project skeleton (owner: main)
- [x] `Help/GNUmakefile` (APPLICATION, links gnustep-gui/base, SYSTEM domain)
- [x] `main.m`, `AppController` stub, minimal menu, empty window launches
- [x] Builds warning-free

### M1 - Core document model + tests (subagent A)
- [x] `GSHelpNode` base + subclasses: Section, Heading, Paragraph, Text,
      CodeBlock, List, ListItem, Table/Row/Cell, Image, Link, Quote, Anchor,
      APIObject
- [x] `GSHelpDocument` (title, identifier, sourceURL, sourceType, rootNode,
      tableOfContents, anchors, metadata)
- [x] `GSHelpParser` protocol + `GSHelpParserRegistry`
- [x] `GSHelpURL`: help://app/..., help://man/&lt;cmd&gt;/&lt;sec&gt;, help://gsdoc/...
- [x] Tests: `Tests/Core/t_Core_*.m`

### M2 - Parsers, parallel after M1 headers exist (subagents B, C, D)
- B: `GSMarkdownParser` - headings, paragraphs, emphasis/strong/inline code,
  fenced+indented code, nested lists, blockquotes, links, images, tables,
  hr; TOC from headings; anchors; malformed input must not crash.
- C: `GSManParser` - .TH/.SH/.SS/.PP/.IP/.HP/.TP/.B/.BI/.BR/.IR/.RB/.RI/
  .nf/.fi, escaping, gz/bz2/xz compressed pages, metadata (command, section,
  shortDescription), man cross-refs like printf(3); fallback to text on
  garbage roff.
- D: `GSTextParser` (paragraph detection, monospaced flag, man-ref
  detection) + format detection helpers (extension vs content sniffing:
  .md/.markdown/N.roff/.gsdoc/plain, gzip/bzip2/xz magic).

### M3 - Renderer + UI shell (subagent E, after M1/M2 APIs stable)
- [x] `GSHelpDocumentView` inside NSScrollView; renders nodes natively
      (text views / attributed strings, selectable+copyable, code blocks in
      monospace boxes, tables, local images)
- [x] Main window per SPEC 36: toolbar Back/Forward/Search field, sidebar
      NSOutlineView with Contents generated from document TOC
- [x] Appearance from GNUstep defaults, no hard-coded fonts

### M4 - Navigation + integration (owner: main, after M3)
- [x] History stack (back/forward), open documents via registry by URL/path
- [x] CLI: `Help.app <file>`, `--man <cmd> [section]`
- [x] App discovery: scan .app/Resources/Help for index.md / Help.plist
- [x] Full build clean, no warnings; install SYSTEM; DriveUI smoke test

### M5 - Search (follow-up, only if M0-M4 land solidly)
- Inverted `GSHelpSearchIndex`, ranking per SPEC 41, sidebar Search mode.

### Deferred (not this pass)
- GSdoc XML parser + API browser (Phase 3), bookmarks persistence, printing,
  zoom persistence, localization dirs, NSHelpManager registration.

## Execution order

```
M0 (main) -> M1 (A) -> [M2 B || M2 C || M2 D] -> M3 (E) -> M4 (main)
```

Subagents are monitored; stuck/hung ones (deadlocked gmake, endless loops)
are killed and their work package re-dispatched or taken over directly.

## Verification

- All test tools green: `for t in ./obj/t_*; do ... done | grep Failed` = 0
- `gmake clean && gmake` zero warnings
- App launches, opens README.md and a real man page, sidebar TOC works
