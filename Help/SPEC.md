# GNUstep Help.app — Complete Technical Specification

**Status:** Proposed
**Target:** GNUstep desktop
**Primary implementation:** Objective-C + GNUstep GUI/Base
**Application:** `Help.app`
**Core library:** `GSHelp`

---

# 1. Purpose

`Help.app` is a native GNUstep documentation viewer for three primary documentation classes:

1. **Command-line tools** — Unix `man` pages
2. **GUI applications** — Markdown documentation
3. **GNUstep frameworks** — GSdoc documentation

The application shall provide a single consistent interface for all three, while preserving the semantics of each source format.

The central architectural principle is:

> **Markdown, man pages, and GSdoc are input formats. They are converted into a common internal documentation model before rendering.**

The application shall **not require an HTML parser, HTML rendering engine, web browser component, JavaScript engine, or network connection.**

---

# 2. Format policy

The project should deliberately keep the supported format set small.

| Documentation      | Format     | Parser             |
| ------------------ | ---------- | ------------------ |
| Command-line tools | man/roff   | `GSManParser`      |
| GUI applications   | Markdown   | `GSMarkdownParser` |
| GNUstep frameworks | GSdoc/XML  | `GSGSDocParser`    |
| Fallback           | Plain text | `GSTextParser`     |

There should be no HTML dependency.

RTF/RTFD support is also not required for the initial architecture. If legacy support becomes necessary later, it can be added as another parser without affecting the core.

---

# 3. Why three formats?

The formats should be chosen according to the kind of information being documented rather than trying to standardize on a single markup language.

## Markdown

Best suited to:

* application guides;
* tutorials;
* installation instructions;
* feature descriptions;
* user workflows;
* configuration documentation;
* troubleshooting;
* general prose.

Markdown is deliberately simple and can be authored with ordinary text editors.

## man

Best suited to:

* command-line programs;
* shell commands;
* utilities;
* system commands;
* command options;
* environment variables;
* exit statuses;
* configuration files.

A man parser allows Help.app to understand existing Unix documentation directly.

## GSdoc

Best suited to:

* GNUstep frameworks;
* Objective-C classes;
* protocols;
* categories;
* methods;
* functions;
* constants;
* API relationships.

GSdoc is not merely another prose format. Its semantic API information is valuable and should be retained.

---

# 4. GSdoc is not obsolete

GSdoc should be treated as a first-class GNUstep documentation format.

Although Markdown is now widely used for general documentation, Markdown does not naturally model an Objective-C API.

For example, GSdoc can distinguish:

```text
Class
Category
Protocol
Instance method
Class method
Function
Constant
Variable
Typedef
Enumeration
```

It can also express relationships between API objects.

Therefore the framework documentation pipeline should remain:

```text
GSdoc
  ↓
GSGSDocParser
  ↓
GSHelpDocument
  ↓
Help.app
```

rather than:

```text
GSdoc
  ↓
Markdown
  ↓
Help.app
```

Converting GSdoc to Markdown would discard information.

---

# 5. Overall architecture

```text
                       Help.app
                          │
             ┌────────────┴────────────┐
             │                         │
        Navigation                  Search
             │                         │
             └────────────┬────────────┘
                          │
                   GSHelpDocument
                          │
             ┌────────────┼────────────┐
             │            │            │
             ▼            ▼            ▼
        Markdown         man         GSdoc
        Parser          Parser       Parser
             │            │            │
             └────────────┼────────────┘
                          │
                       Sources
```

The UI must never need to know whether the current document originated from Markdown, man, or GSdoc.

---

# 6. Core library

The reusable library should be called:

```text
GSHelp
```

Recommended components:

```text
GSHelpCore
GSHelpMarkdown
GSHelpMan
GSHelpGSDoc
GSHelpGUI
```

`Help.app` consumes these components.

The long-term goal should be that another GNUstep application could use `GSHelp` without depending on Help.app.

---

# 7. Core document model

Define:

```objc
GSHelpDocument
```

with properties conceptually equivalent to:

```objc
NSString *title;
NSString *identifier;
NSURL *sourceURL;
NSString *sourceType;
NSString *language;
NSString *version;

GSHelpNode *rootNode;

NSArray *tableOfContents;
NSDictionary *anchors;
NSDictionary *metadata;
```

The source URL is a filesystem/resource URL only. It is not a web URL.

---

# 8. Document nodes

The normalized document model should contain:

```text
GSHelpNode
GSHelpSection
GSHelpHeading
GSHelpParagraph
GSHelpText
GSHelpCodeBlock
GSHelpList
GSHelpListItem
GSHelpTable
GSHelpTableRow
GSHelpTableCell
GSHelpImage
GSHelpLink
GSHelpAnchor
GSHelpQuote
GSHelpAPIObject
```

The exact Objective-C class hierarchy may be adjusted during implementation, but all parsers must produce equivalent semantic structures.

---

# 9. Parser protocol

Define a common parser interface:

```objc
@protocol GSHelpParser <NSObject>

- (BOOL)canParseURL:(NSURL *)url;

- (GSHelpDocument *)parseURL:(NSURL *)url
                        error:(NSError **)error;

@end
```

A parser registry should provide:

```text
GSHelpParserRegistry
```

with operations equivalent to:

```objc
- registerParser:
- unregisterParser:
- parserForURL:
- parsers
```

Built-in parsers:

```text
GSMarkdownParser
GSManParser
GSGSDocParser
GSTextParser
```

---

# 10. Format detection

The parser selection system should use more than filename extensions.

Detection priority:

1. Explicitly specified format
2. Application/help-bundle metadata
3. File extension
4. File contents
5. Plain-text fallback

Examples:

```text
README.md
README.markdown
foo.1
foo.1.gz
Foo.gsdoc
README
```

must be recognized appropriately.

---

# 11. Markdown parser

`GSMarkdownParser` is responsible for GUI application documentation.

The parser should support a well-defined Markdown dialect rather than attempting to support every extension invented by different Markdown implementations.

The initial dialect should support:

* headings;
* paragraphs;
* emphasis;
* strong emphasis;
* inline code;
* fenced code blocks;
* indented code blocks;
* unordered lists;
* ordered lists;
* nested lists;
* block quotations;
* links;
* images;
* tables;
* horizontal rules.

---

# 12. StepDown integration

The Markdown implementation should be designed so that StepDown can be reused where practical.

The dependency should be isolated:

```text
StepDown
    ↓
GSMarkdownParser
    ↓
GSHelpDocument
```

StepDown must not become the application's document model.

If StepDown provides an AST, the AST should be translated into the `GSHelpDocument` representation.

If StepDown's implementation changes later, only the Markdown parser adapter should need modification.

---

# 13. Markdown restrictions

Markdown links should be interpreted as **documentation/resource links**, not as a mechanism requiring a web engine.

Supported link targets:

```text
relative document
relative anchor
local file
help:// internal reference
```

External web links may be recognized as text or handed to an external application, but Help.app must not contain a web renderer.

The core documentation viewer must remain completely independent of web technology.

---

# 14. Application documentation layout

A GUI application should be able to provide:

```text
MyApplication.app/
    Resources/
        Help/
            index.md
            getting-started.md
            preferences.md
            troubleshooting.md
            images/
                preferences.png
```

`index.md` is the canonical entry point.

---

# 15. Help manifest

Applications may provide:

```text
Resources/Help/Help.plist
```

Example:

```text
{
    FormatVersion = 1;

    Title = "My Application";
    Identifier = "org.example.MyApplication.help";

    Index = "index.md";

    Contents = (
        {
            Title = "Getting Started";
            File = "getting-started.md";
        },
        {
            Title = "Preferences";
            File = "preferences.md";
        }
    );
}
```

The manifest is optional.

Without it, Help.app constructs navigation automatically from document headings.

---

# 16. Markdown table of contents

When no explicit TOC exists, headings determine the hierarchy:

```text
H1 → level 1
H2 → level 2
H3 → level 3
H4 → level 4
```

Example:

```text
Getting Started
    Installation
    First Launch
    Configuration

Using the Application
    Projects
    Preferences
    Keyboard Shortcuts

Troubleshooting
```

The sidebar should be generated from this hierarchy.

---

# 17. Markdown application metadata

Help.app should inspect application metadata for:

```text
application name
display name
bundle identifier
version
localization
```

The help bundle may override these values where explicitly specified.

---

# 18. man parser

`GSManParser` is responsible for Unix command documentation.

The parser should read man source directly whenever possible.

It should not rely on launching `man`, capturing terminal output, and attempting to reconstruct the original structure.

The desired pipeline is:

```text
man source
    ↓
GSManParser
    ↓
GSHelpDocument
```

---

# 19. man discovery

Help.app should search configured man paths.

Sources include:

1. `MANPATH`;
2. system-configured man directories;
3. local man directories;
4. GNUstep installation directories;
5. explicitly registered documentation directories.

The implementation must not hard-code a particular operating system layout.

---

# 20. man compression

The parser should support compressed man pages when the required decompression functionality is available.

At minimum:

```text
.gz
.bz2
.xz
```

The decompressed data is passed directly to `GSManParser`.

---

# 21. roff support

The parser should support the common man macros:

```text
.TH
.SH
.SS
.PP
.IP
.HP
.TP
.B
.BI
.BR
.IR
.RB
.RI
.nf
.fi
```

The parser does not need to implement the entire roff language.

The objective is to correctly parse normal Unix manual pages, not to implement a general typesetting system.

---

# 22. man normalization

Example:

```text
.TH ls 1
.SH NAME
ls \- list directory contents
.SH SYNOPSIS
.B ls
[OPTION]...
[FILE]...
.SH DESCRIPTION
...
```

becomes:

```text
GSHelpDocument
    Heading: NAME
        Paragraph

    Heading: SYNOPSIS
        CodeBlock

    Heading: DESCRIPTION
        Paragraph
```

The parser also extracts:

```text
command = ls
section = 1
shortDescription = list directory contents
```

as document metadata.

---

# 23. man table of contents

The sidebar should display man sections:

```text
ls(1)

NAME
SYNOPSIS
DESCRIPTION
OPTIONS
OPERANDS
ENVIRONMENT
EXIT STATUS
EXAMPLES
FILES
SEE ALSO
```

The list is generated from the actual sections present in the page.

---

# 24. man cross-references

The parser should recognize references such as:

```text
printf(3)
ls(1)
make(1)
foo(5)
```

and resolve them against the installed man catalog.

Selecting the reference opens the corresponding document.

---

# 25. GSdoc parser

`GSGSDocParser` reads GSdoc XML using a proper XML parser.

Regular expressions must not be used for XML parsing.

The parser must preserve semantic information including:

```text
classes
categories
protocols
methods
functions
variables
constants
macros
typedefs
enumerations
declarations
parameters
return values
discussion
examples
references
availability
```

---

# 26. GSdoc semantic model

Define:

```text
GSHelpAPIObject
```

with fields equivalent to:

```text
kind
name
qualifiedName
declaration
abstract
discussion
availability
parameters
returnValue
seeAlso
sourceLocation
```

Supported object kinds:

```text
class
category
protocol
instance-method
class-method
function
variable
constant
macro
typedef
enum
field
```

---

# 27. API declarations

Declarations should be rendered as dedicated code/declaration blocks.

For example:

```objc
- (NSString *)stringByAppendingString:(NSString *)aString;
```

The declaration must be:

* selectable;
* copyable;
* printable;
* visually distinct from prose.

Syntax highlighting is optional for the initial implementation.

---

# 28. GSdoc API hierarchy

The sidebar should expose semantic API navigation.

Example:

```text
Foundation
    Classes
        NSArray
        NSDictionary
        NSString

    Protocols
        NSCopying
        NSCoding

    Functions

    Constants
```

Selecting a class opens its reference page.

---

# 29. Class documentation

A class page should provide:

```text
NSString

Overview

Tasks
    Creating Strings
    Comparing Strings
    Searching Strings
    Extracting Characters

Class Methods
    string
    stringWithFormat:

Instance Methods
    length
    substringFromIndex:
```

The actual sections should be generated from GSdoc semantic information.

---

# 30. API cross-references

GSdoc references should resolve automatically where possible.

For:

```text
NSString
```

the resolver searches registered GSdoc documentation for a matching class.

For:

```text
-[NSString length]
```

the resolver searches for:

```text
class = NSString
selector = length
kind = instance method
```

Only high-confidence matches should become automatic links.

---

# 31. Internal Help URLs

Help.app should use an internal URL namespace:

```text
help://
```

These are application-internal identifiers, not network resources.

Examples:

```text
help://app/MyApplication/index
help://man/ls/1
help://gsdoc/Foundation/NSString
```

The URL implementation should be independent of physical source filenames.

---

# 32. Markdown links to API documentation

Application documentation may directly reference framework APIs:

```markdown
[`NSString`](help://gsdoc/Foundation/NSString)
```

This allows Markdown application documentation to link directly into GSdoc framework documentation.

---

# 33. Document renderer

The renderer must consume only `GSHelpDocument`.

It must not contain format-specific parsing logic.

Pipeline:

```text
Source
  ↓
Parser
  ↓
GSHelpDocument
  ↓
Layout
  ↓
Native GNUstep views
```

This ensures that Markdown, man, and GSdoc have a consistent appearance.

---

# 34. Native rendering

The initial renderer should use GNUstep GUI controls and views.

Suggested architecture:

```text
NSScrollView
    └── GSHelpDocumentView
          ├── text elements
          ├── code blocks
          ├── images
          ├── lists
          └── tables
```

There should be no requirement for an embedded browser engine.

---

# 35. Layout engine

A dedicated layout layer is recommended:

```text
GSHelpDocument
       ↓
GSHelpLayoutEngine
       ↓
GSHelpLayout
       ↓
GSHelpDocumentView
```

This allows the same document to be rendered for:

* screen;
* printing;
* accessibility;
* future export.

---

# 36. Main window

The Help.app window should have:

```text
┌───────────────────────────────────────────────────────────────┐
│  Back  Forward   Search Documentation                         │
├────────────────┬──────────────────────────────────────────────┤
│                │                                              │
│  CONTENTS      │                 Document                     │
│                │                                              │
│  Application   │       Getting Started                        │
│    Overview    │                                              │
│    Features    │       Welcome to the application...          │
│    Preferences │                                              │
│                │       Installation                            │
│  GNUstep       │                                              │
│    Base        │       ...                                    │
│    GUI         │                                              │
│                │                                              │
│  Commands      │                                              │
│    Tools       │                                              │
│                │                                              │
└────────────────┴──────────────────────────────────────────────┘
```

The interface should be compact, hierarchical, and optimized for documentation navigation.

---

# 37. Toolbar

Required controls:

* Back;
* Forward;
* Search.

Optional controls:

* Home;
* Print;
* bookmarks.

---

# 38. Sidebar

The sidebar should use `NSOutlineView` or an equivalent GNUstep hierarchy control.

Logical modes:

```text
Contents
Search
Bookmarks
```

The implementation may use tabs, segmented controls, or another suitable UI.

---

# 39. Search

Search must operate across all registered local documentation.

The user searches one documentation system rather than three separate databases.

Example:

```text
NSString
```

may return:

```text
NSString
Foundation
Class Reference

stringWithFormat:
Foundation
Class Method

String Handling
Application Guide
```

---

# 40. Search index

Define:

```text
GSHelpSearchIndex
```

Each indexed document should provide:

```text
documentID
title
heading
body
keywords
sourceType
application
framework
symbol
manSection
internalURL
```

The first implementation should use an inverted index.

---

# 41. Search ranking

Initial ranking:

```text
exact symbol match      +100
exact title match       +100
man NAME match           +80
title token              +50
heading token            +30
keyword token            +25
body token               +10
```

Objective-C selectors should be normalized during indexing so that searches remain useful despite punctuation.

---

# 42. Search scopes

The search UI should eventually provide:

```text
All Documentation
This Application
GNUstep
Man Pages
Current Document
```

The first implementation may expose these as a popup menu associated with the search field.

---

# 43. Search result presentation

Each result displays:

```text
Title
Source
Context
Excerpt
```

Example:

```text
NSString
Foundation
Class Reference

stringWithFormat:
Foundation
NSString class method

Window Preferences
My Application
User Guide
```

---

# 44. Navigation history

Define:

```text
GSHelpNavigationEntry
```

containing:

```text
internalURL
documentIdentifier
anchor
scrollPosition
selection
```

Back and Forward operate on these entries.

Opening a link creates a new history entry.

Simple scrolling does not.

---

# 45. Bookmarks

Bookmarks may refer to:

* documents;
* headings;
* classes;
* methods;
* functions;
* man sections;
* anchors.

Each bookmark contains:

```text
title
internalURL
anchor
dateAdded
```

Bookmarks persist across launches.

---

# 46. Recent documents

Help.app maintains a persistent recent-document list.

Default limit:

```text
20
```

The limit may be configurable.

---

# 47. Printing

Printing shall render the normalized document rather than printing the Help.app window.

Printed pages should contain:

```text
Document title
Page number
```

API documentation should additionally identify the framework and API object.

Man pages should identify the command and section.

---

# 48. Copying

Document text must be selectable and copyable.

Code blocks must copy as source text.

API declarations must copy as source declarations.

---

# 49. Images

Markdown documentation may contain local images.

Images should support:

* intrinsic dimensions;
* scaling;
* maximum width;
* alt text;
* optional captions.

Images must be local documentation resources.

Help.app does not need a remote image-loading system.

---

# 50. Tables

Markdown tables should support:

* header rows;
* alignment;
* wrapping;
* horizontal scrolling.

Tables must not permanently expand the entire document beyond the viewport.

---

# 51. Plain-text fallback

`GSTextParser` provides the final fallback for unknown documentation.

It should:

* preserve line endings;
* detect paragraphs;
* detect local documentation references;
* detect man references where practical;
* support monospaced presentation for terminal-oriented content.

---

# 52. Documentation catalog

Define:

```text
GSHelpCatalog
```

It maintains registered documentation sources.

Each source contains:

```text
identifier
title
path
type
priority
language
version
```

Source types:

```text
Application
Framework
Man
System
User
Other
```

---

# 53. Application discovery

Help.app should discover application documentation from application resources.

Preferred structure:

```text
Application.app/
    Resources/
        Help/
```

The scanner should recognize:

```text
index.md
Help.plist
*.md
```

and appropriate localization directories.

---

# 54. Framework discovery

Framework documentation may be installed in:

```text
Framework.framework/
    Documentation/

Framework.framework/
    Resources/
        Documentation/
```

or in GNUstep documentation directories.

The scanner should recognize GSdoc sources and generated documentation where applicable.

No HTML support is required.

---

# 55. Documentation precedence

When several versions of documentation are available:

1. application-local documentation;
2. explicitly selected framework documentation;
3. current GNUstep installation;
4. system documentation;
5. generic fallback.

Documentation from different versions must not be silently combined.

---

# 56. Version metadata

Documentation sources may specify:

```text
FrameworkVersion
ApplicationVersion
MinimumVersion
MaximumVersion
```

This allows multiple framework versions to coexist.

---

# 57. Localization

Help.app must support localized application documentation.

Recommended structure:

```text
Help/
    en.lproj/
        index.md
    de.lproj/
        index.md
    fr.lproj/
        index.md
```

Language selection follows the normal GNUstep localization mechanism.

Search should use Unicode-aware normalization and case folding.

---

# 58. Appearance

The document renderer should use GNUstep system preferences for:

* fonts;
* text color;
* background color;
* selection color;
* link appearance.

Fonts must not be hard-coded.

---

# 59. Accessibility

All navigation must be keyboard accessible.

Required operations:

* Tab;
* arrow-key navigation;
* Enter;
* search;
* copy;
* print;
* Back;
* Forward;
* zoom.

Document nodes should expose useful accessibility information.

---

# 60. Zoom

Provide:

```text
View → Actual Size
View → Zoom In
View → Zoom Out
```

Zoom changes document content size without changing the sidebar size.

The zoom setting may be persisted per document.

---

# 61. Security

Help.app must treat documentation as untrusted input.

It must not:

* execute scripts;
* execute programs;
* load remote content;
* automatically launch applications;
* interpret documentation as shell commands.

Documentation should be limited to parsing and displaying content.

---

# 62. Resource sandboxing

A document may load:

* resources within its own help bundle;
* resources within its registered documentation root;
* explicitly referenced local resources.

It must not arbitrarily read unrelated files from the filesystem.

---

# 63. Offline operation

All core documentation functionality must work without network access.

The application must not require network access for:

* Markdown;
* man;
* GSdoc;
* search;
* framework documentation;
* application documentation.

This is a fundamental requirement.

---

# 64. Command-line interface

Help.app shall support:

```text
Help.app <path>
```

Examples:

```text
Help.app README.md
Help.app foo.1
Help.app Foo.gsdoc
Help.app MyApplication.app
```

It should additionally support:

```text
Help.app --man ls
Help.app --man printf 3
Help.app --search "NSString"
Help.app --help-url help://gsdoc/Foundation/NSString
```

---

# 65. Help manager integration

Applications should be able to request help through GNUstep's help infrastructure.

The intended architecture is:

```text
Application
    ↓
NSHelpManager / GSHelp integration
    ↓
Help.app
```

Help.app should become the standard graphical consumer of application help requests.

---

# 66. Help viewer registration

Help.app should register itself as a GNUstep help viewer capable of handling:

```text
Markdown
man
GSdoc
plain text
```

The implementation should use the help-viewer selection mechanism provided by the target GNUstep release.

---

# 67. No HTML dependency

The following are explicitly **out of scope**:

```text
HTML parser
HTML renderer
Web browser engine
JavaScript engine
CSS engine
remote resource loading
web navigation
```

This keeps Help.app:

* lightweight;
* native;
* deterministic;
* offline;
* easier to maintain;
* easier to port across GNUstep backends.

---

# 68. Project structure

Recommended source tree:

```text
Help.app/
├── GNUmakefile
├── Sources/
│   ├── main.m
│   ├── AppController.m
│   │
│   ├── Core/
│   │   ├── GSHelpDocument.m
│   │   ├── GSHelpNode.m
│   │   ├── GSHelpSource.m
│   │   ├── GSHelpCatalog.m
│   │   ├── GSHelpURL.m
│   │   └── GSHelpSearchIndex.m
│   │
│   ├── Parsers/
│   │   ├── GSHelpParserRegistry.m
│   │   ├── GSMarkdownParser.m
│   │   ├── GSManParser.m
│   │   ├── GSGSDocParser.m
│   │   └── GSTextParser.m
│   │
│   ├── Rendering/
│   │   ├── GSHelpRenderer.m
│   │   ├── GSHelpLayout.m
│   │   ├── GSHelpDocumentView.m
│   │   └── GSHelpCodeView.m
│   │
│   ├── Navigation/
│   │   ├── GSHelpNavigationController.m
│   │   ├── GSHelpBookmarkController.m
│   │   └── GSHelpHistory.m
│   │
│   └── UI/
│       ├── HelpWindowController.m
│       ├── HelpSidebarController.m
│       ├── HelpSearchController.m
│       └── HelpToolbarController.m
│
├── Resources/
│   ├── MainMenu.gorm
│   └── Help/
│
└── Tests/
    ├── Markdown/
    ├── Man/
    ├── GSDoc/
    ├── Search/
    ├── Navigation/
    └── UI/
```

---

# 69. Testing

Every parser requires unit tests.

## Markdown

Test:

* headings;
* paragraphs;
* links;
* images;
* code;
* tables;
* nested lists;
* malformed Markdown;
* Unicode.

## man

Test:

* `.TH`;
* `.SH`;
* `.SS`;
* `.B`;
* `.BI`;
* `.BR`;
* `.IP`;
* `.TP`;
* `.nf`;
* `.fi`;
* escaping;
* compressed pages;
* malformed roff;
* cross-references.

## GSdoc

Test:

* classes;
* categories;
* protocols;
* methods;
* functions;
* constants;
* declarations;
* cross-references;
* examples;
* malformed XML;
* Unicode;
* Objective-C selectors.

---

# 70. Golden document tests

Each parser should have input files and expected normalized document structures.

For example:

```text
Tests/
    Man/
        ls.1
        ls.expected

    Markdown/
        application.md
        application.expected

    GSDoc/
        Foundation.gsdoc
        Foundation.expected
```

The expected representation should verify:

* title;
* metadata;
* node hierarchy;
* TOC;
* anchors;
* links;
* semantic API objects.

---

# 71. Search tests

Search should test:

```text
NSString
stringWithFormat
window delegate
ls
ls(1)
printf(3)
```

Exact API and command matches should rank higher than incidental text matches.

---

# 72. UI tests

The UI test suite should verify:

1. Open Markdown documentation.
2. Open a man page.
3. Open GSdoc documentation.
4. Navigate through the TOC.
5. Follow an internal link.
6. Press Back.
7. Press Forward.
8. Search.
9. Open a search result.
10. Add a bookmark.
11. Restart Help.app.
12. Verify bookmark persistence.
13. Copy a code block.
14. Print a document.
15. Open documentation from the command line.

---

# 73. Performance

Target performance:

```text
Small Markdown document:       < 250 ms
Typical man page:              < 250 ms
Typical GSdoc document:        < 500 ms
Indexed search:                < 200 ms
```

These are development targets, not strict guarantees.

Large documentation collections should be indexed asynchronously.

---

# 74. Threading

Parsing, indexing, and filesystem scanning must not block the GUI.

Architecture:

```text
Main Thread
    │
    ├── UI
    ├── Navigation
    └── User interaction
            │
            ▼
       Worker threads
            │
            ├── Parsing
            ├── Indexing
            └── Discovery
```

Results are dispatched back to the main thread.

---

# 75. Cancellation

Search, indexing, and documentation discovery should support cancellation.

A new search should cancel or supersede an old search.

A document scan should be cancellable when the user quits or changes the requested operation.

---

# 76. Error handling

Malformed documentation must never crash Help.app.

Example:

```text
Unable to display this document.

The GSdoc source contains invalid XML.

[Show Details]
```

Where possible, parsers should recover and display the valid portions of a document.

---

# 77. Parser fallback

If a parser fails:

```text
Markdown → Plain text
GSdoc → Plain text/XML fallback
man → Plain text
```

The user should still be able to inspect the underlying documentation.

---

# 78. Initial implementation phases

## Phase 1 — Core and Markdown

Implement:

* `GSHelpDocument`;
* parser registry;
* Markdown parser;
* plain-text parser;
* application help discovery;
* document renderer;
* TOC;
* navigation;
* search;
* bookmarks.

## Phase 2 — man

Implement:

* man discovery;
* roff parser;
* man metadata;
* man section navigation;
* cross-references;
* command search.

## Phase 3 — GSdoc

Implement:

* XML parsing;
* GSdoc semantic model;
* class browser;
* protocol browser;
* method browser;
* API cross-references.

## Phase 4 — GNUstep integration

Implement:

* help-manager integration;
* help viewer registration;
* framework discovery;
* application registration;
* `help://` identifiers.

---

# 79. Minimum viable release

The first release should contain:

```text
✓ Help.app
✓ Native GNUstep UI
✓ GSHelp core library
✓ Markdown parser
✓ man parser
✓ GSdoc parser
✓ Plain-text fallback
✓ Application help discovery
✓ GNUstep framework discovery
✓ Search
✓ Table of contents
✓ Back/Forward
✓ Bookmarks
✓ Internal documentation links
✓ Local images
✓ Printing
✓ Command-line opening
✓ help:// identifiers
✓ No HTML dependency
✓ No network dependency
```

---

# 80. Final architecture

The final system should be:

```text
                    ┌─────────────────┐
                    │     Help.app    │
                    └────────┬────────┘
                             │
                      GSHelpDocument
                             │
          ┌──────────────────┼──────────────────┐
          │                  │                  │
          ▼                  ▼                  ▼
      Markdown              man               GSdoc
          │                  │                  │
          ▼                  ▼                  ▼
    GUI application     Command line       Framework/API
      documentation      documentation       documentation
```

The three formats have deliberately different roles:

* **Markdown** is the general-purpose format for application documentation.
* **man/roff** is the native format for command-line documentation.
* **GSdoc** is the structured format for GNUstep API documentation.

They should coexist rather than compete.

The implementation should therefore focus on a strong common `GSHelpDocument` model and high-quality parsers, rather than trying to force every documentation source into one markup language.

The most important architectural constraint is:

> **Help.app is a native documentation viewer, not a web browser.**

No HTML parser, browser engine, JavaScript runtime, CSS engine, or network subsystem is required.
