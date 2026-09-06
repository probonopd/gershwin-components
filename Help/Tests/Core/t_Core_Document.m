/* Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/* t_Core_Document - node tree building, TOC derivation, anchor lookup,
 * document properties. Links Core sources as separate objects. */

#import <Foundation/Foundation.h>
#import "Testing.h"

#import "GSHelpNode.h"
#import "GSHelpDocument.h"

int main(void)
{
  NSAutoreleasePool *arp = [NSAutoreleasePool new];

  START_SET("node tree building")
  {
    GSHelpSection *root = [GSHelpSection new];
    root.title = @"Root";

    GSHelpSection *sub = [GSHelpSection new];
    sub.title = @"Sub";
    [root appendNode: sub];

    GSHelpParagraph *para = [GSHelpParagraph new];
    GSHelpText *run = [GSHelpText new];
    run.string = @"hello";
    run.style = GSHelpTextStyleBold;
    [para appendNode: run];
    [sub appendNode: para];

    PASS(root.children.count == 1, "root has one child");
    PASS(root.children[0] == sub, "child is the appended section");
    PASS(sub.parent == root, "appendNode sets parent");
    PASS(para.parent == sub, "nested parent set");
    PASS(run.parent == para, "deep parent set");
    PASS([root.children[0] isKindOfClass: [GSHelpSection class]],
         "children keep their dynamic type");
  }
  END_SET("node tree building")

  START_SET("subclass properties")
  {
    GSHelpHeading *h = [GSHelpHeading new];
    h.text = @"Install";
    h.level = 2;
    PASS_EQUAL(h.text, @"Install", "heading text");
    PASS(h.level == 2, "heading level stored");
    h.level = 99;
    PASS(h.level == 4, "heading level clamped high to 4");
    h.level = 0;
    PASS(h.level == 1, "heading level clamped low to 1");

    GSHelpCodeBlock *cb = [GSHelpCodeBlock new];
    cb.code = @"ls -l";
    cb.language = @"sh";
    PASS_EQUAL(cb.code, @"ls -l", "code block code");
    PASS_EQUAL(cb.language, @"sh", "code block language");

    GSHelpList *list = [GSHelpList new];
    PASS(list.isOrdered == NO, "default list is unordered");
    list.ordered = YES;
    PASS(list.isOrdered == YES, "ordered flag stored");

    GSHelpImage *img = [GSHelpImage new];
    img.path = @"images/prefs.png";
    img.altText = @"Preferences";
    PASS_EQUAL(img.path, @"images/prefs.png", "image path");
    PASS_EQUAL(img.altText, @"Preferences", "image alt text");

    GSHelpQuote *quote = [GSHelpQuote new];
    PASS([quote isKindOfClass: [GSHelpNode class]], "quote is a node");

    GSHelpAnchor *anchor = [GSHelpAnchor new];
    anchor.name = @"installation";
    PASS_EQUAL(anchor.name, @"installation", "anchor name");
  }
  END_SET("subclass properties")

  START_SET("link label runs")
  {
    GSHelpLink *link = [GSHelpLink new];
    link.target = @"help://gsdoc/Foundation/NSString";
    [link appendLabelRun: @"NS" style: GSHelpTextStyleBold];
    [link appendLabelRun: @"String" style: GSHelpTextStylePlain];

    PASS(link.labelRuns.count == 2, "two label runs");
    PASS([link.labelRuns[0] isKindOfClass: [GSHelpText class]],
         "label runs are GSHelpText");
    PASS(link.labelRuns[0].style == GSHelpTextStyleBold,
         "first run bold");
    PASS(link.labelRuns[0].parent == link, "run parent is the link");
    PASS_EQUAL(link.labelRuns[1].string, @"String", "second run text");
    PASS_EQUAL(link.labelText, @"NSString", "concatenated label text");
  }
  END_SET("link label runs")

  START_SET("table structure")
  {
    GSHelpTable *table = [GSHelpTable new];
    GSHelpTableRow *header = [GSHelpTableRow new];
    [header appendCellWithText: @"Key"];
    [header appendCellWithText: @"Value"];
    GSHelpTableRow *row = [GSHelpTableRow new];
    [row appendCellWithText: @"lang"];
    [table appendNode: header];
    [table appendNode: row];

    PASS(table.rows.count == 2, "table exposes its rows");
    PASS(header.cells.count == 2, "row exposes its cells");
    PASS(header.cells[0].parent == header, "cell parent is row");
    PASS_EQUAL(table.rows[0].cells[1].text, @"Value",
               "cell text via table accessors");
  }
  END_SET("table structure")

  START_SET("TOC derivation")
  {
    /* Root
     *   H1 A
     *     H2 B
     *   H1 C       <- inside a nested section, still in order */
    GSHelpSection *root = [GSHelpSection new];

    GSHelpHeading *hA = [GSHelpHeading new];
    hA.text = @"A"; hA.level = 1;
    GSHelpParagraph *pA = [GSHelpParagraph new];
    [pA appendNode: [GSHelpText new]];
    [root appendNode: hA];
    [root appendNode: pA];

    GSHelpHeading *hB = [GSHelpHeading new];
    hB.text = @"B"; hB.level = 2;
    [root appendNode: hB];

    GSHelpSection *sub = [GSHelpSection new];
    GSHelpHeading *hC = [GSHelpHeading new];
    hC.text = @"C"; hC.level = 1;
    [sub appendNode: hC];
    [root appendNode: sub];

    GSHelpDocument *doc = [GSHelpDocument new];
    doc.rootNode = root;

    NSArray *toc = doc.tableOfContents;
    PASS(toc != nil && toc.count == 3, "TOC has all three headings");
    PASS(toc.count == 0 || ([toc[0] heading] == hA
                            && [toc[0] level] == 1),
         "first entry is heading A at level 1");
    PASS(toc.count < 2 || ([toc[1] heading] == hB
                           && [toc[1] level] == 2),
         "second entry is heading B at level 2");
    PASS(toc.count < 3 || [toc[2] heading] == hC,
         "third entry is heading C from nested section");
    PASS(doc.tableOfContents == toc,
         "TOC derived lazily and cached");

    GSHelpDocument *emptyDoc = [GSHelpDocument new];
    PASS(emptyDoc.tableOfContents.count == 0,
         "no root -> empty TOC, no crash");
  }
  END_SET("TOC derivation")

  START_SET("anchor lookup")
  {
    GSHelpSection *root = [GSHelpSection new];
    GSHelpParagraph *para = [GSHelpParagraph new];
    GSHelpAnchor *a1 = [GSHelpAnchor new];
    a1.name = @"one";
    GSHelpAnchor *a2 = [GSHelpAnchor new];
    a2.name = @"two";
    [para appendNode: a1];
    [root appendNode: a2];
    [root appendNode: para];

    GSHelpDocument *doc = [GSHelpDocument new];
    doc.rootNode = root;

    PASS(doc.anchors.count == 2, "both anchors found");
    PASS(doc.anchors[@"one"] == a1,
         "anchor 'one' resolves to its node");
    PASS(doc.anchors[@"two"] == a2, "anchor 'two' found deep");
    PASS(doc.anchors[@"missing"] == nil,
         "unknown anchor yields nil");
  }
  END_SET("anchor lookup")

  START_SET("derived data invalidation")
  {
    GSHelpSection *root1 = [GSHelpSection new];
    GSHelpHeading *h1 = [GSHelpHeading new];
    h1.text = @"First"; h1.level = 1;
    [root1 appendNode: h1];

    GSHelpSection *root2 = [GSHelpSection new];
    GSHelpHeading *h2 = [GSHelpHeading new];
    h2.text = @"Second"; h2.level = 1;
    [root2 appendNode: h2];

    GSHelpDocument *doc = [GSHelpDocument new];
    doc.rootNode = root1;
    NSString *firstText = doc.tableOfContents.count == 1
        ? [[doc.tableOfContents[0] heading] text] : nil;
    PASS_EQUAL(firstText, @"First", "TOC reflects first root");
    doc.rootNode = root2;
    NSString *secondText = doc.tableOfContents.count == 1
        ? [[doc.tableOfContents[0] heading] text] : nil;
    PASS_EQUAL(secondText, @"Second",
               "reassigning root recomputes TOC");
    PASS(doc.anchors.count == 0,
         "anchors recomputed for new root");
  }
  END_SET("derived data invalidation")

  START_SET("document properties")
  {
    NSURL *src = [NSURL URLWithString: @"file:///usr/share/doc/index.md"];
    GSHelpDocument *doc = [GSHelpDocument new];
    doc.title = @"Guide";
    doc.identifier = @"org.example.Guide.help";
    doc.sourceURL = src;
    doc.sourceType = @"markdown";
    doc.metadata = @{ @"version": @"1.0" };

    PASS_EQUAL(doc.title, @"Guide", "title");
    PASS_EQUAL(doc.identifier, @"org.example.Guide.help", "identifier");
    PASS([doc.sourceURL isEqual: src], "sourceURL round-trip");
    PASS_EQUAL(doc.sourceType, @"markdown", "sourceType");
    PASS_EQUAL([doc.metadata objectForKey: @"version"], @"1.0",
               "metadata value");
  }
  END_SET("document properties")

  [arp release];
  return 0;
}
