# ``SwiftXState/Actor``

## Overview

An `Actor` is a running instance of a ``StateMachine``. Create one with `createActor(_:)`,
boot it with ``start(input:context:)``, drive it with ``send(_:)``, and read its current
``MachineSnapshot`` from ``snapshot``. See <doc:RunningActors> for a full walkthrough.

## Topics

### Lifecycle

- ``start(input:context:)``
- ``stop()``
- ``status``

### Sending Events

- ``send(_:)``

### Reading State

- ``snapshot``
- ``getPersistedSnapshot()``

### Observing

- ``subscribe(_:)``

### Identity

- ``id``
- ``sessionId``
- ``machine``
- ``actorSystem``
