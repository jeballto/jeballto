# ``EventBus``

## Overview

`EventBus` is a non-blocking pub/sub system for VM lifecycle events. Subscribers receive a `SubscriptionToken` that they use to unsubscribe. Callbacks are dispatched to `DispatchQueue.global(qos: .userInitiated)`, so one slow subscriber cannot block others or the publisher.

Thread safety is achieved via a concurrent `DispatchQueue` with barrier writes for subscription management, and serial dispatch for event delivery ordering.

The bus retains up to the last 1000 events in memory. Events are queryable per-VM or globally.

All 30+ event types are cases of ``VMEvent``. Use ``VMEvent/eventType`` to get a string identifier for logging or API serialization.

## Topics

### Subscribing

- ``subscribe(_:)``
- ``unsubscribe(_:)``
- ``SubscriptionToken``

### Publishing

- ``publish(_:)``

### Event History

- ``getEvents(forVM:limit:)``
- ``getAllEvents(limit:)``
- ``clearHistory()``

### Diagnostics

- ``subscriberCount``
- ``eventCount``
