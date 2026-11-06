# Beacon static website

A responsive, dependency-free implementation of the approved dark Beacon concept. All interface text, project rows, feature tiles, menu preview and buttons are HTML. The lighthouse landscape is the only generated bitmap.

## Preview

Run `npm run dev` from this folder. The preview server calls `beacon register beacon-site --json` on every launch, binds to the returned port on `127.0.0.1`, and prints https://beacon-site.test. Beacon must be installed and running.

## Hosting

The relay image (`Relay/Dockerfile`) copies the HTML, CSS and JavaScript listed in its `COPY` statements, plus the Beacon symbol, Docker symbol and lighthouse WebP, into `/srv/site`, and `beacon-relay` serves them on its apex. `BEACON_HOME=card` switches back to the plain card; see `Relay/README.md`. If the page starts using another asset, add it to the `COPY` lines in the Dockerfile. Link assets with plain relative paths in quotes (`href="styles.css"`): the relay adds `?v=<hash>` to those itself, so caches pick up changes.

Any static host works too: deploy the same files. `server.mjs` is only a local preview convenience.

## Mockups

The two interface previews follow the real app, so update them when the app changes:

- The hero panel is the menu bar panel (`MenuPanel.swift`): project cards with a folder icon, a domain and its assigned port, a status pill and a ••• menu holding the row's real actions.
- The window in the Getting started section is the Settings window (`SettingsPanel.swift`), with its real panes: General, Sharing, Coding agents, Service, Updates.
- The sharing terminal shows what `beacon share` prints (`Sources/beacon/ShareCommands.swift`).
- The self-hosting steps condense "Running your own relay" in the main README. Keep the two in step.
- The terminal shows what `beacon register` prints (`Output.describe` in `Sources/beacon/Output.swift`).

## Design and behavior

- Brand colours: Signal `#F5B544`, Ink `#181C20`, Canvas `#F5F3EE`, Slate `#737C86`, Online `#38A88A`.
- The supplied Beacon vector symbol is used throughout. The dark wordmark is a live-text approximation.
- The coastal background progressively blurs toward its lower edge using aligned CSS image layers; page text and interface elements stay sharp.
- Window borders retain a static masked conic gradient. Visible panel rims gently change opacity; feature-icon rims stay static. Moving highlights use small HTML elements animated with transform and opacity, rather than repainting SVG strokes or gradients. Off-screen and hidden-tab motion pauses, and reduced-motion preferences disable animation and smooth scrolling.
- Settings tabs, the ••• row menu and the example-project dialog run locally in the browser. They do not change Beacon or register real projects. Added examples are intentionally temporary. Project rows and their decorative ellipses do not copy anything; only the visibly labelled Copy button beside the terminal command writes to the clipboard.
- Download, GitHub, documentation and release links come from the local Beacon project README and Git remote.
- The current landscape was generated with the built-in image-generation tool, then compressed to WebP. Prompt: a physically believable lighthouse on a stormy Atlantic sea cliff at blue hour, amber lantern and beam, dark slate ocean, irregular waves and soft storm clouds; clean cinematic finish, smooth atmospheric transitions, no uniform microtexture or repeating patterns, and dark negative space for website text.

The website uses `assets/lighthouse-sunset.webp`, with the full-resolution sunset version in `assets/lighthouse-sunset.png`. The edit adds amber sunset light beneath the storm clouds while preserving the coastline and cool sea. The earlier coastal version remains in `assets/lighthouse-coast.png` and `assets/lighthouse-coast.webp`. The previous mountain assets remain available as `assets/lighthouse.png` and `assets/lighthouse.webp`.

## Sharing illustration

The sharing flow uses static HTML/SVG artwork with small moving HTML highlights, a pause control, and a static reduced-motion presentation. The Mac initiates the tunnel; requests and responses use it in opposite directions.

The unmodified white Docker symbol comes from [Docker’s official logo kit](https://www.docker.com/company/newsroom/media-resources/). Docker and the Docker logo are trademarks or registered trademarks of Docker, Inc. in the United States and/or other countries.

## Self-hosting guide

The four setup tabs illustrate DNS, HTTPS, deployment and team invitations. The panel keeps a fixed size between steps, supports arrow keys and Home/End, and reflows on smaller screens. Examples are illustrative; links open the actual setup documentation and Compose file.

## Page structure and decoration

The page runs from the hero through Sharing, the combined Features section, Coding agents, Getting started, Self-hosting and the final download link. Browser startup and Docker support have larger feature cards; the registration terminal and Settings window share one section. Sharing links directly to relay setup.

- `page-order.css` controls the consolidated feature cards, paired setup previews and alternating sharing layout.
- `atmosphere.css` and `atmosphere.js` add coastal light, static contour artwork and small travelling highlights. The light fills wide viewports while contour edges fade smoothly. Path positions are sampled on resize, with no per-frame JavaScript loop. The footer control pauses decorative animations, including the traffic illustration and panel rims.
- `chrome.css` and `chrome.js` add static illuminated dividers and sticky navigation. A small glass surface appears when the top sentinel leaves the viewport, without a scroll handler or layout shift. Anchor offsets keep headings visible below the navigation.

The local preview server retains the project's `beacon-site` registration. The separate design-review server is not part of the project.
