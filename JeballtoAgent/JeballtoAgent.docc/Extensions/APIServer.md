# ``APIServer``

## Overview

`APIServer` owns the `SimpleHTTPServer` instance and registers all route handlers. Bearer token authentication is
enforced inside `SimpleHTTPServer` before every route handler except `/v1/health`. Handlers for protected routes can
assume the request is authenticated.

Route handlers are registered in `registerRoutes()` at startup and organized into domain groups, each implemented as `extension APIServer` in a separate file under `APIServer/Routes/`.

The server binds to `config.api.host:config.api.port` (default `0.0.0.0:8011`). Local clients can use `http://127.0.0.1:8011`.

See <doc:DevelopmentGuide> for a walkthrough of adding new endpoints.

## Topics

### Lifecycle

- ``start()``
- ``stop()``

### Dependencies

- ``vmManager``
- ``imageManager``
- ``portForwardingManager``
- ``eventBus``
- ``config``
