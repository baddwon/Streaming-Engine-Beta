# Custom Streaming Engine v0.3.1

## Highlights

This release focuses on playlist reliability, global audio source management, UI cleanup, and foundational work for future maintenance mode, network security, and diagnostics features.

## Added

- Global audio source management stored in system settings.
- Reusable audio sources available across all channels.
- Support for web-based audio stream sources.
- Maintenance asset framework.
- Default maintenance slate image package support.
- Engineer page tab persistence via URL parameters.
- Outputs roadmap section for future multi-output support.

## Improved

- Playlist editing workflow.
- Playlist change application and output restart handling.
- Audio source application and output restart handling.
- Engineer page layout and navigation.
- Settings page organization and readability.
- Output visibility and status reporting.
- HLS output information display.
- Channel management workflows.
- Persistence of playlist settings across restarts.

## Fixed

- Playlist order persistence across container restarts.
- Drag-and-drop playlist ordering.
- Audio source persistence across restarts.
- Disabled content state persistence.
- Channel deletion cleanup.
- Stale HLS output cleanup.
- Duplicate output restart behaviors.
- Multiple UI navigation inconsistencies.
- Removal of legacy localhost dependencies.

## Assets

Default maintenance slate assets are now stored under:

/channels/system/assets/maintenance

Included resolutions:

- 720p
- 1080p
- 4K
- 8K

## Upcoming

Planned future work:

- Network Security tab
- Firewall policy preview
- NTP and timezone management
- Maintenance Mode
- Output resolution selection: 720p / 1080p / 4K
- Expanded diagnostics dashboard
- System resource monitoring
- Multi-output support: HLS, UDP, RTMP, SRT
