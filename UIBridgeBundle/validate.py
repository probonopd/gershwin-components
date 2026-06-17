#!/usr/bin/env python3.11
"""Validate the extracted UIBridge.bundle in the live harness (no /System install).
Autoloads the bundle via GSAppKitUserBundles (absolute path) in the sandbox.

Distinguishing signal: the bundle's id-registry issues object ids like 'objc:1'
(small ints); the old in-Eau pointer-cast issued 'objc:0x<hex>'. So the id
*format* reveals which service is answering — and proves the registry path runs.
"""
import os, re, sys
sys.path.insert(0, "/home/micha/eau-theme-work/specimen-pub/tests")
sys.path.insert(0, os.path.expanduser("~/build/goldstep"))
import spec_harness as SH
from goldstep.xephyr import Xephyr

BUNDLE = "/home/micha/eau-theme-work/UIBridgeBundle/UIBridge.bundle"
EAU    = "/home/micha/eau-theme-work/eau-4b4ae74-normal.theme"   # 4b4ae74+searchfix
assert os.path.isdir(BUNDLE), "bundle missing: " + BUNDLE

def classify(idstr):
    if not idstr: return "none"
    if re.match(r"^objc:\d+$", idstr): return "REGISTRY(objc:int)"
    if re.match(r"^objc:0x", idstr):   return "pointer(objc:0xhex)"
    return "other(%s)" % idstr

def run(label, theme, with_bundle):
    extra = {"GSAppKitUserBundles": [BUNDLE]} if with_bundle else None
    kw = {"theme": theme, "ready_timeout": 90, "require_dump": True}
    if extra: kw["extra_defaults"] = extra
    print("\n===== %s =====" % label, flush=True)
    try:
        with Xephyr(1280, 900) as xeph:
            with SH.Session("Buttons", display=xeph.display, **kw) as s:
                root = s.bridge.get_root()
                wins = root.get("windows", [])
                appid = root.get("NSApp")
                wid = wins[0].get("object_id") if wins else None
                print("  ALIVE  NSApp=%r windows=%d" % (appid, len(wins)), flush=True)
                print("  NSApp id class:  %s" % classify(appid), flush=True)
                print("  window id class: %s (%r)" % (classify(wid), wid), flush=True)
                # registry round-trip: resolve a window id back to details
                if wid:
                    d = s.bridge.get_details(wid)
                    ok = isinstance(d, dict) and d.get("class")
                    print("  details(window) -> class=%s  [round-trip %s]" %
                          (d.get("class") if isinstance(d, dict) else d, "OK" if ok else "FAIL"), flush=True)
                btns = s.bridge.find(cls="NSButton") or []
                print("  find NSButton -> %d" % len(btns), flush=True)
    except Exception as e:
        print("  FAILED: %r" % (e,), flush=True)

run("A: base theme, NO bundle (baseline: does base already have a service?)", False, False)
run("B: base theme + UIBridge.bundle (theme-independent introspection)", False, True)
run("C: Eau theme + UIBridge.bundle", EAU, True)
