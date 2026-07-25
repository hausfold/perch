# ADR 0001: Stage private copies and export copy-only drags

Status: accepted

## Context

A temporary shelf must survive source-window closure, iCloud eviction, source
renames, app relaunch, and consumers that inspect a drag asynchronously.
Retaining only the original URL is fast but cannot guarantee those properties.
Advertising move allows a destination to remove the shelf's only durable copy.

## Decision

Perch copies every accepted representation into an app-owned UUID container.
Outgoing dragging sessions advertise only `NSDragOperation.copy`. Clearing the
shelf is a separate explicit operation, optionally automatic after AppKit
reports a successful copy drag.

## Consequences

Large imports take time and consume storage, but run off-main and are visible as
pending transfers. Originals are never put at risk. A future move-original
feature must be an explicit transaction with its own authorization and recovery
record.
