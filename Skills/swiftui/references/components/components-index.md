# Components Index

Use this file to find component-specific guidance. Each entry lists when to use it.

## Available components

- TabView: `tabview.md` — Use when building a tab-based app or any tabbed feature set.
- NavigationStack: `navigationstack.md` — Use when you need push navigation and programmatic routing, especially per-tab history.
- Sheets and modal routing: `sheets.md` — Use when you want centralized, enum-driven sheet presentation.
- App wiring and dependency graph: `app-wiring.md` — Use to wire TabView + NavigationStack + sheets at the root and install global dependencies.
- Form and Settings: `form.md` — Use for settings, grouped inputs, and structured data entry.
- macOS Settings: `macos-settings.md` — Use when building a macOS Settings window with SwiftUI's Settings scene.
- Split views and columns: `split-views.md` — Use for iPad/macOS multi-column layouts or custom secondary columns.
- List and Section: `list.md` — Use for feed-style content and settings rows.
- ScrollView and Lazy stacks: `scrollview.md` — Use for custom layouts, horizontal scrollers, or grids.
- Grids: `grids.md` — Use for icon pickers, media galleries, and tiled layouts.
- Theming and dynamic type: `theming.md` — Use for app-wide theme tokens, colors, and type scaling.
- Controls (toggles, pickers, sliders): `controls.md` — Use for settings controls and input selection.
- Input toolbar (bottom anchored): `input-toolbar.md` — Use for chat/composer screens with a sticky input bar.
- Top bar overlays (iOS 26+ and fallback): `top-bar.md` — Use for pinned selectors or pills above scroll content.
- Overlay and toasts: `overlay.md` — Use for transient UI like banners or toasts.
- Focus handling: `focus.md` — Use for chaining fields and keyboard focus management.
- Searchable: `searchable.md` — Use for native search UI with scopes and async results.
- Async images and media: `media.md` — Use for remote media, previews, and media viewers.
- Haptics: `haptics.md` — Use for tactile feedback tied to key actions.
- Matched transitions: `matched-transitions.md` — Use for smooth source-to-destination animations.
- Deep links and URL routing: `deeplinks.md` — Use for in-app navigation from URLs.
- Title menus: `title-menus.md` — Use for filter or context menus in the navigation title.
- Menu bar commands: `menu-bar.md` — Use when adding or customizing macOS/iPadOS menu bar commands.
- Loading & placeholders: `loading-placeholders.md` — Use for redacted skeletons, empty states, and loading UX.
- Lightweight clients: `lightweight-clients.md` — Use for small, closure-based API clients injected into stores.

## Adding entries

- Add the component file and link it here with a short “when to use” description.
- Keep each component reference short and actionable.
